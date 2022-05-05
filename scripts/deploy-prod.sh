#------------------------------------------------------------------------------
# written by: mcdaniel
# date: feb-2022
#
# usage: deploy a Tutor-created openedx Docker image to the Kubernetes cluster.
#        The openedx docker image is created by a Github action in tutor-build.git.
#
#        The general work flow in this action is:
#        ----------------------------------------
#        I.   Bootstrap the Github Actions Ubuntu instance.
#        II.  Get backend services configuration data stored in Kubernetes secrets
#        III. Configure Open edX by setting environment variables
#        IV.  Merge all of the configuration data into Tutor's Open edX configuration files
#        V.   Deploy Open edX into the Kubernetes cluster
#
# requires:
# - jq python3 python3-pip libyaml-dev
# - aws-cli using an IAM key/secret for a user with admin privileges
# - kubectl connected as the EKS owner or a user listed in the aws-auth configMap
#------------------------------------------------------------------------------
ENVIRONMENT_ID="prod"
NAMESPACE="openedx"
TUTOR_VERSION="v13.2.0"
OPENEDX_COMMON_VERSION="open-release/maple.3"
OPENEDX_CUSTOM_THEME="custom-edx-theme"


# get the Kubernetes kubeconfig for our cluster. This is a prerequisite to getting any other data about or contained within our cluster.
# see: https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
#
# summarizing: the kubeconfig (Kubernetes Configuration) is a text file that contains at a minimum
# three values that are necessary in order to access the Kubernetes cluster using kubectl command line:
#   - API server endpoint
#   - EKS Cluster ARN
#   - Certificate authority (ie the private ssh key)
aws eks --region us-east-1 update-kubeconfig --name prod-academiacentral-global --alias eks-prod

# install the latest version of python3 which is a prerequisite for running Tutor
sudo apt install jq python3 python3-pip libyaml-dev
pip install --upgrade pyyaml

TUTOR_ROOT=$GITHUB_WORKSPACE/tutor

if [ ! -d ~/tutor ]; then
    git clone https://github.com/overhangio/tutor.git
fi

cd ~/tutor
git checkout ${TUTOR_VERSION}
pip install -e .
TUTOR_VERSION=$(tutor --version | cut -f3 -d' ')

#------------------------------------------------------------------------
# II. Get all of our backend configuration data that was stored in
#     Kubernetes secrets by various Terraform modules
#------------------------------------------------------------------------

# retrieve the Open edX JWT token that we created with Terraform and
# then stored in Kubernetes secrets
# see: https://github.com/academiacentral-org/openedx_devops/blob/main/terraform/modules/kubernetes_secrets/main.tf
### Fetch secrets from Kubernetes into Environment
jwt_private_key=$(kubectl get secret jwt -n $NAMESPACE -o json |  jq  '.data| map_values(@base64d)'  | jq -r 'keys[] as $k | "\(.[$k])"')

# retrieve the MySQL connection parameters that we created in Terraform
# and then stored in Kubernetes secrets. These include:
#   MYSQL_HOST: mysql.mooc.moocweb.com
#   MYSQL_PORT: "3306"
#   OPENEDX_MYSQL_USERNAME: openedx
#   OPENEDX_MYSQL_PASSWORD: **************
#   MYSQL_ROOT_USERNAME: root
#   MYSQL_ROOT_PASSWORD: *************
#
# Also note that we are using jq to add a prefix of "TUTOR_" to each of the parameter names
#
# see: https://github.com/academiacentral-org/openedx_devops/blob/main/terraform/modules/mysql/main.tf
TUTOR_RUN_MYSQL=false
kubectl get secret mysql-root -n $NAMESPACE  -o json | jq  '.data | map_values(@base64d)' | jq -r 'keys[] as $k | "TUTOR_\($k|ascii_upcase)=\(.[$k])"'
kubectl get secret mysql-openedx -n $NAMESPACE  -o json | jq  '.data | map_values(@base64d)' | jq -r 'keys[] as $k | "TUTOR_\($k|ascii_upcase)=\(.[$k])"'

# retrieve the Redis connection parameter that we created in Terraform:
#   REDIS_HOST: redis.mooc.moocweb.com
#
# see: https://github.com/academiacentral-org/openedx_devops/blob/main/terraform/modules/redis/main.tf
TUTOR_RUN_REDIS=false
kubectl get secret redis -n $NAMESPACE  -o json | jq  '.data | map_values(@base64d)' | jq -r 'keys[] as $k | "TUTOR_\($k|ascii_upcase)=\(.[$k])"'

#------------------------------------------------------------------------
# III. Configure Open edX by setting environment variables
#------------------------------------------------------------------------

# ---------------------------------------------------------------------------------
# Note: We're not managing AWS SES with Terraform simply because the service is fiddly
# and AWS is neurotic about any changes to the config.
# ---------------------------------------------------------------------------------
TUTOR_RUN_SMTP=true
tutor config save --set EMAIL_BACKEND="django.core.mail.backends.smtp.EmailBackend" \
                --set EMAIL_HOST="email-smtp.us-east-1.amazonaws.com" \
                --set EMAIL_HOST_PASSWORD="CHANGE-ME" \
                --set EMAIL_HOST_USER="CHANGE-ME" \
                --set EMAIL_PORT=587 \
                --set EMAIL_USE_TLS=true

# see: https://github.com/academiacentral-org/openedx_devops/blob/main/terraform/modules/kubernetes_secrets/main.tf
kubectl get secret edx-secret-key -n $NAMESPACE  -o json | jq  '.data | map_values(@base64d)' | jq -r 'keys[] as $k | "TUTOR_\($k|ascii_upcase)=\(.[$k])"'

# Pin the instalation ID with the Kubernetes namespace. It needs to be unique and static per instalation.
cat ~/openedx_devops/ci/tutor-deploy/environments/${ENVIRONMENT_ID}/config.yml

# note that values like $LMS_HOSTNAME come from this repo
# in /~/openedx_devops/ci/tutor-deploy/environments/prod/config.yml
# We don't want to run these services as we are using the Kubernetes ingress instead.
TUTOR_ID=tutor-$NAMESPACE
TUTOR_LMS_HOST=$LMS_HOSTNAME
TUTOR_CMS_HOST=$CMS_HOSTNAME
TUTOR_K8S_NAMESPACE=$NAMESPACE
TUTOR_DOCKER_IMAGE_OPENEDX=$DOCKER_IMAGE_OPENEDX
TUTOR_RUN_CADDY=false
TUTOR_RUN_NGINX=false

# note that the Kubernetes additional config data is locally
# stored in ~/openedx_devops/ci/tutor-deploy/environments/prod/k8s/
# in Kubernetes manifest yaml format
# Create kubernetes ingress and other environment resources
kubectl apply -f "~/openedx_devops/ci/tutor-deploy/environments/$ENVIRONMENT_ID/k8s"

# Notes: OPENEDX_AWS_ACCESS_KEY, OPENEDX_AWS_SECRET_ACCESS_KEY and S3_STORAGE_BUCKET
#        are stored in EKS kubernetes secrets, viewable from k9s.
#        example values:
#          OPENEDX_AWS_ACCESS_KEY: ABDCE123456789OHBBGQ
#          OPENEDX_AWS_SECRET_ACCESS_KEY: A123456789srJ8lgel+ABCDEFGHIJKabcdefghijk
#          S3_STORAGE_BUCKET: prod-academiacentral-global-storage
#          S3_CUSTOM_DOMAIN: cdn.mooc.moocweb.com
#          S3_REGION: us-east-1
#
# this config depends on a public read-only AWS S3 bucket policy like this:
# https://github.com/academiacentral-org/terraform-openedx/blob/main/components/s3/main.tf#L19
#
#      {
#          "Version": "2012-10-17",
#          "Statement": [
#              {
#                  "Sid": "",
#                  "Effect": "Allow",
#                  "Principal": "*",
#                  "Action": [
#                      "s3:GetObject*",
#                      "s3:List*"
#                  ],
#                  "Resource": "arn:aws:s3:::prod-academiacentral-global-storage/*"
#              }
#          ]
#      }
#
kubectl get secret s3-openedx-storage -n $NAMESPACE  -o json | jq  '.data | map_values(@base64d)' | jq -r 'keys[] as $k | "TUTOR_\($k|ascii_upcase)=\(.[$k])"'

pip install git+https://github.com/hastexo/tutor-contrib-s3@v0.2.0
tutor plugins enable s3

tutor config save --set OPENEDX_AWS_ACCESS_KEY="$OPENEDX_AWS_ACCESS_KEY" \
                --set OPENEDX_AWS_SECRET_ACCESS_KEY="$OPENEDX_AWS_SECRET_ACCESS_KEY" \
                --set OPENEDX_AWS_QUERYSTRING_AUTH="False" \
                --set OPENEDX_AWS_S3_SECURE_URLS="False" \
                --set S3_STORAGE_BUCKET="$S3_STORAGE_BUCKET" \
                --set S3_CUSTOM_DOMAIN="$S3_CUSTOM_DOMAIN" \
                --set S3_REGION="$S3_REGION"

#tutor config save --set OPENEDX_FACEBOOK_APP_ID="${{ secrets.FACEBOOK_APP_ID }}" \
#                --set OPENEDX_FACEBOOK_APP_SECRET="${{ secrets.FACEBOOK_APP_SECRET }}"

export TUTOR_JWT_RSA_PRIVATE_KEY=\'$(sed -E 's/$/\n/g' ./jwt_private_key)\'
tutor --version
tutor config save
cat $TUTOR_ROOT/config.yml

#------------------------------------------------------------------------
# IV. Merge all of the configuration data into Tutor's Open edX
#     configuration files: config.yml, lms.env.json, cms.env.json
#
# In this step we're combining three sources of data:
# 1. sensitive configuration data retrieved from Kubernetes secrets in section II above
# 2. Open edx application and services configuration data created here in section III
# 3. LMS and CMS application configuration data stored in our repo at ~/openedx_devops/ci/tutor-deploy/environments/prod/settings_merge.json
#------------------------------------------------------------------------
echo "config.yml full path: $(tutor config printroot)/config.yml"
cd $TUTOR_ROOT/env/apps/openedx/config/

mv lms.env.json lms.env.json.orig
jq -s '.[0] * .[1]'  lms.env.json.orig  "~/openedx_devops/ci/tutor-deploy/environments/$ENVIRONMENT_ID/settings_merge.json" >  lms.env.json

mv cms.env.json cms.env.json.orig
jq -s '.[0] * .[1]'  cms.env.json.orig  "~/openedx_devops/ci/tutor-deploy/environments/$ENVIRONMENT_ID/settings_merge.json" >  cms.env.json
rm *orig

#------------------------------------------------------------------------
# V. Deploy Open edX
#------------------------------------------------------------------------
tutor k8s start
tutor k8s init
tutor k8s settheme $OPENEDX_CUSTOM_THEME

$(kubectl get secret admin-edx -n $NAMESPACE  -o json | jq  '.data | map_values(@base64d)' |   jq -r 'keys[] as $k | "export \($k|ascii_upcase)=\(.[$k])"')
tutor k8s createuser --password "$ADMIN_PASSWORD" --staff --superuser "$ADMIN_USER" admin@moocweb.com
