## EBS CSI Storage Driver

# Allow PVCs backed by EBS
module "eks_ebs_csi_irsa" {
  count   = var.ebs_csi_driver ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.33.0"

  role_name             = "${var.cluster_name}-ebs-csi-role"
  attach_ebs_csi_policy = true
  ebs_csi_kms_cmk_ids   = [var.kms_manage ? aws_kms_key.this[0].arn : module.eks.kms_key_arn]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["${var.ebs_csi_driver_namespace}:ebs-csi-controller-sa"]
    }
  }

  tags = var.tags
}

resource "helm_release" "aws_ebs_csi_driver" {
  count            = var.ebs_csi_driver ? 1 : 0
  chart            = "aws-ebs-csi-driver"
  create_namespace = var.ebs_csi_driver_namespace == "kube-system" ? false : true
  name             = "aws-ebs-csi-driver"
  namespace        = var.ebs_csi_driver_namespace
  repository       = "https://kubernetes-sigs.github.io/aws-ebs-csi-driver"
  version          = var.ebs_csi_driver_version
  wait             = var.ebs_csi_driver_wait

  values = [
    yamlencode({
      controller = {
        extraVolumeTags = var.tags
        serviceAccount = {
          annotations = {
            "eks.amazonaws.com/role-arn" = "arn:${local.aws_partition}:iam::${local.aws_account_id}:role/${var.cluster_name}-ebs-csi-role"
          }
        }
      }
      image = {
        repository = "${var.csi_ecr_repository_id}.dkr.ecr.${local.aws_region}.amazonaws.com/eks/aws-ebs-csi-driver"
      }
    }),
    yamlencode(var.ebs_csi_driver_values),
  ]

  depends_on = [
    module.eks_ebs_csi_irsa[0],
    module.eks,
  ]
}

# Make EBS CSI with gp3 default storage driver
resource "kubernetes_storage_class" "eks_ebs_storage_class" {
  count = var.ebs_csi_driver ? 1 : 0

  metadata {
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
    labels = {}
    name   = "ebs-sc"
  }

  mount_options = var.ebs_storage_class_mount_options
  parameters = merge(
    var.ebs_storage_class_parameters,
    {
      kmsKeyId = var.kms_manage ? aws_kms_key.this[0].id : module.eks.kms_key_id
    }
  )
  storage_provisioner = "ebs.csi.aws.com"
  volume_binding_mode = "WaitForFirstConsumer"

  depends_on = [
    helm_release.aws_ebs_csi_driver[0],
  ]
}

# Don't want gp2 storageclass set as default.
resource "kubernetes_annotations" "eks_disable_gp2" {
  count = var.ebs_csi_driver ? 1 : 0

  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  metadata {
    name = "gp2"
  }
  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "false"
  }
  force = true

  depends_on = [
    kubernetes_storage_class.eks_ebs_storage_class[0]
  ]
}
