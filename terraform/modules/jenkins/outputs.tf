output "public_ip" {
  description = "Elastic IP of the Jenkins instance (stable across reboots)"
  value       = aws_eip.jenkins.public_ip
}

output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.jenkins.id
}

output "jenkins_url" {
  description = "Jenkins UI URL"
  value       = "http://${aws_eip.jenkins.public_ip}:8080"
}

output "initial_password_command" {
  description = "Command to retrieve the Jenkins initial admin password"
  value       = "ssh ubuntu@${aws_eip.jenkins.public_ip} 'sudo cat /var/lib/jenkins/secrets/initialAdminPassword'"
}

output "iam_role_arn" {
  description = "IAM role ARN attached to the Jenkins instance"
  value       = aws_iam_role.jenkins.arn
}
