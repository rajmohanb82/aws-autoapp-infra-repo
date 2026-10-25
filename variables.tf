variable "region" {
  default = "ap-south-1"
}
variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "production"], var.environment)
    error_message = "Use dev or production."

  }
}
variable "certificate_arn" {
  type = string
}
variable "allowed_cidrs" {
  type = list(string)
  validation {
    condition     = length(var.allowed_cidrs) > 0 && alltrue([for c in var.allowed_cidrs : can(cidrnetmask(c)) && c != "0.0.0.0/0"])
    error_message = "Supply restricted IPv4 client CIDRs; this administrative portal must not be open to the internet."

  }
}
variable "ami_id" {
  type        = string
  description = "Tested x86_64 Amazon Linux 2023 AMI in this region."
}
variable "alert_email" {
  type = string
}
variable "backup_role_arn" {
  type = string
}
variable "runtime_assume_role_arns" {
  type        = list(string)
  default     = []
  description = "Explicit cross-account read-only audit roles. Remediation permissions require a separate review."
}
