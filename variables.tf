variable "cluster_name" {
  type    = string
  default = "demo-eks-cluster"
}

variable "cluster_version" {
  type    = string
  default = "1.32"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "availability_zones" {
  type    = list(any)
  default = ["us-east-1a", "us-east-1b"]
}



variable "addons" {
  type = list(object({
    name    = string
    version = string
  }))

  default = [
    {
      name    = "kube-proxy"
      version = "v1.32.0-eksbuild.2"
    },
    {
      name    = "vpc-cni"
      version = "v1.19.2-eksbuild.1"
    },
    {
      name    = "coredns"
      version = "v1.11.4-eksbuild.2"
    },
    {
      name    = "aws-ebs-csi-driver"
      version = "v1.38.1-eksbuild.1"
    }
  ]
}
