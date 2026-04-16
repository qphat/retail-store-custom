aws_region         = "us-east-1"
env_name           = "eks-dev"
cidr_block         = "10.1.0.0/16"
az_count           = 2
k8s_version        = "1.32"
node_instance_type = "t3.medium"
node_desired       = 2
node_min           = 1
node_max           = 3

# Jenkins — set jenkins_allowed_cidr to your IP before applying
# Find your IP: curl ifconfig.me
jenkins_instance_type = "t3.medium"
jenkins_allowed_cidr  = "0.0.0.0/0"   # REPLACE with your IP: "x.x.x.x/32"
