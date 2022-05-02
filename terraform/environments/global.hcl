#------------------------------------------------------------------------------
# written by: Lawrence McDaniel
#             https://lawrencemcdaniel.com/
#
# date: Feb-2022
#
# usage: create global parameters, exposed to all
#        Terragrunt modules in this repository.
#------------------------------------------------------------------------------
locals {
  platform_name    = "academiacentral"
  platform_region  = "global"
  root_domain      = "academiacentral.org"
  aws_region       = "us-east-1"
  account_id       = "765796256872"
  ec2_ssh_key_name = "uedx"

  tags = {
    Platform        = local.platform_name
    Platform-Region = local.platform_region
    Terraform       = "true"
  }

}

inputs = {
  platform_name    = local.platform_name
  platform_region  = local.platform_region
  aws_region       = local.aws_region
  account_id       = local.account_id
  root_domain      = local.root_domain
  ec2_ssh_key_name = local.ec2_ssh_key_name
}
