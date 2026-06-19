terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  #backend "s3" {
   # bucket = "drift-detective-tf-state-mofa-p3" 
    #key    = "terraform.tfstate"               
    #region = "us-east-1"                      
    #encrypt = true                             
  #}
}

provider "aws" {
  region = "us-east-1"
  profile = "default"
}

resource "aws_s3_bucket" "terraform_state" {
  bucket        = "drift-detective-tf-state-mofa-p3" 
  force_destroy = true 
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = {
    Name = "DriftDetective-VPC"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "us-east-1a"
  tags = {
    Name = "DriftDetective-Public-Subnet"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "DriftDetective-IGW"
  }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = {
    Name = "DriftDetective-Public-RT"
  }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_subnet" "public_2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "us-east-1b" 
  tags = { Name = "DriftDetective-Public-Subnet-2" }
}

resource "aws_db_subnet_group" "main" {
  name       = "drift-detective-db-subnets"
  subnet_ids = [aws_subnet.public.id, aws_subnet.public_2.id]
  tags = { Name = "DriftDetective DB Subnet Group" }
}

resource "aws_security_group" "ec2_sg" {
  name        = "drift-detective-ec2-sg"
  description = "Allow SSH only from my home IP"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from my IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["106.192.175.156/32"] 
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "rds_sg" {
  name        = "drift-detective-rds-sg"
  description = "Allow Postgres only from the EC2 instance"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Postgres from EC2"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2_sg.id] 
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_instance" "ledger" {
  identifier             = "drift-detective-ledger"
  engine                 = "postgres"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  db_name                = "driftdetective"
  username               = "dbadmin"
  password               = "LoLAlok25" 
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  skip_final_snapshot    = true
  multi_az               = false 
  storage_encrypted      = true
  tags = { Name = "DriftDetective-Ledger" }
}

resource "aws_iam_role" "ec2_role" {
  name = "drift-detective-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "ec2_policy" {
  name = "drift-detective-ec2-policy"
  role = aws_iam_role.ec2_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:DescribeInstances", "ec2:DescribeTags"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "drift-detective-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# 8. Give EC2 permission to talk to AWS Systems Manager (SSM)
resource "aws_iam_role_policy_attachment" "ssm_attach" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# 7. The Auditor: EC2 Instance (Ephemeral)
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

resource "aws_instance" "auditor" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro" 
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name
  key_name               = "drift-detective-key" 
  
  user_data = <<-EOF
              yum update -y
              dnf install -y postgresql15
              EOF

  tags = {
    Name        = "DriftDetective-Auditor"
    Environment = "Terraform-Managed" 
}
}

output "ec2_public_ip" {
  value = aws_instance.auditor.public_ip
}

output "rds_endpoint" {
  value = aws_db_instance.ledger.endpoint
}

resource "aws_iam_role" "lambda_role" {
  name = "drift-detective-lambda-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "drift-detective-lambda-policy"
  role = aws_iam_role.lambda_role.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:StopInstances",
          "ec2:CreateTags",
          "ec2:DescribeInstances"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_lambda_function" "enforcer" {
  filename      = "lambda_function.zip"
  function_name = "drift-detective-enforcer"
  role          = aws_iam_role.lambda_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.9"
  timeout       = 30
  
  environment {
  variables = {
    ENVIRONMENT   = "production"
    SNS_TOPIC_ARN = aws_sns_topic.security_alerts.arn
  }
}
}

resource "aws_iam_role_policy" "ec2_lambda_invoke" {
  name = "drift-detective-ec2-lambda-invoke"
  role = aws_iam_role.ec2_role.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["lambda:InvokeFunction"]
      Resource = aws_lambda_function.enforcer.arn
    }]
  })
}

output "lambda_function_name" {
  value = aws_lambda_function.enforcer.function_name
}

resource "aws_sns_topic" "security_alerts" {
  name = "drift-detective-security-alerts"
}

resource "aws_sns_topic_subscription" "security_team_email" {
  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = "roaringrobin21@gmail.com" 
}

resource "aws_iam_role_policy" "lambda_sns_publish" {
  name = "drift-detective-lambda-sns-publish"
  role = aws_iam_role.lambda_role.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sns:Publish"
      ]
      Resource = aws_sns_topic.security_alerts.arn
    }]
  })
}

output "sns_topic_arn" {
  value = aws_sns_topic.security_alerts.arn
}
