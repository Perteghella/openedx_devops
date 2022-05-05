#------------------------------------------------------------------------------
# written by: mcdaniel
# date: feb-2022
#
# usage: Contingency plan for automated Tutor deployment.
# Based on usf_deploy_prod.yml Github Actions workflow logic.
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
TUTOR_ROOT=~/.local/share/tutor

echo "updated kubeconfig from cluster configuration data in AWS EKS"
aws eks --region us-east-1 update-kubeconfig --name prod-academiacentral-global --alias eks-prod

# install the latest version of python3 which is a prerequisite for running Tutor
sudo apt install jq python3 python3-pip libyaml-dev -y
pip install --upgrade pyyaml


if [ ! -d ~/openedx_devops ]; then
    echo "Cloning openedx_devops"
    git clone https://github.com/academiacentral-org/openedx_devops.git ~/openedx_devops
fi
if [ ! -d ~/tutor ]; then
    echo "Cloning tutor"
    git clone https://github.com/overhangio/tutor.git ~/tutor
fi

cd ~/tutor
git checkout ${TUTOR_VERSION}
pip install -e .
TUTOR_VERSION=$(tutor --version | cut -f3 -d' ')

echo "Getting jwt_private_key from Kubernetes Secretes"
kubectl get secret jwt -n $NAMESPACE -o json |  jq  '.data| map_values(@base64d)'  | jq -r 'keys[] as $k | "\(.[$k])"' > ~/jwt_private_key

echo "Getting MySQL remote configuration from Kubernetes Secretes"
TUTOR_RUN_MYSQL=false
kubectl get secret mysql-root -n $NAMESPACE  -o json | jq  '.data | map_values(@base64d)' | jq -r 'keys[] as $k | "TUTOR_\($k|ascii_upcase)=\(.[$k])"'
kubectl get secret mysql-openedx -n $NAMESPACE  -o json | jq  '.data | map_values(@base64d)' | jq -r 'keys[] as $k | "TUTOR_\($k|ascii_upcase)=\(.[$k])"'

echo "Getting Redis remote configuration from Kubernetes Secretes"
TUTOR_RUN_REDIS=false
kubectl get secret redis -n $NAMESPACE  -o json | jq  '.data | map_values(@base64d)' | jq -r 'keys[] as $k | "TUTOR_\($k|ascii_upcase)=\(.[$k])"'

echo "Configuring SMTP email service"
TUTOR_RUN_SMTP=true
tutor config save --set EMAIL_BACKEND="django.core.mail.backends.smtp.EmailBackend" \
                --set EMAIL_HOST="email-smtp.us-east-1.amazonaws.com" \
                --set EMAIL_HOST_PASSWORD="CHANGE-ME" \
                --set EMAIL_HOST_USER="CHANGE-ME" \
                --set EMAIL_PORT=587 \
                --set EMAIL_USE_TLS=true

echo "Getting edX secret key from Kubernetes Secretes"
kubectl get secret edx-secret-key -n $NAMESPACE  -o json | jq  '.data | map_values(@base64d)' | jq -r 'keys[] as $k | "TUTOR_\($k|ascii_upcase)=\(.[$k])"'

echo "Built-in config.yml consists of the following:"
cat ~/openedx_devops/ci/tutor-deploy/environments/${ENVIRONMENT_ID}/config.yml

TUTOR_ID=tutor-$NAMESPACE
TUTOR_LMS_HOST=$LMS_HOSTNAME
TUTOR_CMS_HOST=$CMS_HOSTNAME
TUTOR_K8S_NAMESPACE=$NAMESPACE
TUTOR_DOCKER_IMAGE_OPENEDX=$DOCKER_IMAGE_OPENEDX
TUTOR_RUN_CADDY=false
TUTOR_RUN_NGINX=false

echo "Create kubernetes ingress and other environment resources"
kubectl apply -f "/home/ubuntu/openedx_devops/ci/tutor-deploy/environments/$ENVIRONMENT_ID/k8s/"

pip install git+https://github.com/hastexo/tutor-contrib-s3@v0.2.0
tutor plugins enable s3

$(kubectl get secret s3-openedx-storage -n $NAMESPACE  -o json | jq  '.data | map_values(@base64d)' | jq -r 'keys[] as $k | "export \($k|ascii_upcase)=\(.[$k])"' )
tutor config save --set OPENEDX_AWS_ACCESS_KEY="$OPENEDX_AWS_ACCESS_KEY" \
                --set OPENEDX_AWS_SECRET_ACCESS_KEY="$OPENEDX_AWS_SECRET_ACCESS_KEY" \
                --set OPENEDX_AWS_QUERYSTRING_AUTH="False" \
                --set OPENEDX_AWS_S3_SECURE_URLS="False" \
                --set S3_STORAGE_BUCKET="$S3_STORAGE_BUCKET" \
                --set S3_CUSTOM_DOMAIN="$S3_CUSTOM_DOMAIN" \
                --set S3_REGION="$S3_REGION"

#tutor config save --set OPENEDX_FACEBOOK_APP_ID="${{ secrets.FACEBOOK_APP_ID }}" \
#                --set OPENEDX_FACEBOOK_APP_SECRET="${{ secrets.FACEBOOK_APP_SECRET }}"

export TUTOR_JWT_RSA_PRIVATE_KEY=\'$(sed -E 's/$/\n/g' ~/jwt_private_key)\'
tutor --version
tutor config save
echo "config.yml:"
cat $(tutor config printroot)/config.yml

echo "config.yml full path: $(tutor config printroot)/config.yml"
cd $TUTOR_ROOT/env/apps/openedx/config/

mv lms.env.json lms.env.json.orig
jq -s '.[0] * .[1]'  lms.env.json.orig  "/home/ubuntu/openedx_devops/ci/tutor-deploy/environments/$ENVIRONMENT_ID/settings_merge.json" >  lms.env.json

mv cms.env.json cms.env.json.orig
jq -s '.[0] * .[1]'  cms.env.json.orig  "/home/ubuntu/openedx_devops/ci/tutor-deploy/environments/$ENVIRONMENT_ID/settings_merge.json" >  cms.env.json
rm *orig

#------------------------------------------------------------------------
# Time to Deploy Open edX!!!
#------------------------------------------------------------------------
tutor k8s start
tutor k8s init
tutor k8s settheme $OPENEDX_CUSTOM_THEME

$(kubectl get secret admin-edx -n $NAMESPACE  -o json | jq  '.data | map_values(@base64d)' |   jq -r 'keys[] as $k | "export \($k|ascii_upcase)=\(.[$k])"')
tutor k8s createuser --password "$ADMIN_PASSWORD" --staff --superuser "$ADMIN_USER" admin@moocweb.com
