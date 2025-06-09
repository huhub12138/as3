#!/bin/bash

# 🚀 Bird Detection System - One-Click AWS Deployment
# This script automates the entire deployment process

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default values
DEFAULT_REGION="us-east-1"
DEFAULT_BUCKET="bird-detection-$(date +%s)"
DEFAULT_INSTANCE_TYPE="t3.medium"

echo -e "${CYAN}🎯 Bird Detection System - One-Click AWS Deployment${NC}"
echo -e "${CYAN}================================================${NC}"

# Function to check prerequisites
check_prerequisites() {
    echo -e "${BLUE}🔍 Checking prerequisites...${NC}"
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        echo -e "${RED}❌ AWS CLI not found. Please install it first.${NC}"
        exit 1
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        echo -e "${RED}❌ AWS credentials not configured. Please run 'aws configure' first.${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✅ Prerequisites check passed!${NC}"
}

# Function to deploy everything
deploy_all() {
    echo -e "${BLUE}🚀 Starting full deployment...${NC}"
    
    # Get region and bucket from user or use defaults
    read -p "Enter AWS region (default: $DEFAULT_REGION): " REGION
    REGION=${REGION:-$DEFAULT_REGION}
    
    read -p "Enter S3 bucket name (default: $DEFAULT_BUCKET): " BUCKET_NAME
    BUCKET_NAME=${BUCKET_NAME:-$DEFAULT_BUCKET}
    
    echo -e "${YELLOW}Using region: $REGION${NC}"
    echo -e "${YELLOW}Using bucket: $BUCKET_NAME${NC}"
    
    # Deploy AWS services
    echo -e "${BLUE}📦 Deploying AWS services...${NC}"
    bash deploy.sh "$BUCKET_NAME" "$REGION"
    
    # Create EC2 deployment instructions
    create_ec2_instructions
    
    echo -e "${GREEN}🎉 Deployment completed!${NC}"
    echo -e "${BLUE}📋 Next steps:${NC}"
    echo -e "1. Check deployment-config.env for AWS resource details"
    echo -e "2. Follow ec2-setup.txt for EC2 deployment"
    echo -e "3. Update your .env file with AWS credentials"
}

# Function to create EC2 setup instructions
create_ec2_instructions() {
    echo -e "${BLUE}📝 Creating EC2 setup instructions...${NC}"
    
    cat > ec2-setup.txt << 'EOF'
🚀 EC2 Setup Instructions
========================

1. Create EC2 Instance:
   aws ec2 create-key-pair --key-name bird-detection-key --query 'KeyMaterial' --output text > bird-detection-key.pem
   aws ec2 create-security-group --group-name bird-detection-sg --description "Bird detection app security group"
   aws ec2 authorize-security-group-ingress --group-name bird-detection-sg --protocol tcp --port 22 --cidr 0.0.0.0/0
   aws ec2 authorize-security-group-ingress --group-name bird-detection-sg --protocol tcp --port 80 --cidr 0.0.0.0/0
   aws ec2 authorize-security-group-ingress --group-name bird-detection-sg --protocol tcp --port 5000 --cidr 0.0.0.0/0
   
   aws ec2 run-instances \
     --image-id ami-0c02fb55956c7d316 \
     --count 1 \
     --instance-type t3.medium \
     --key-name bird-detection-key \
     --security-groups bird-detection-sg

2. Get Instance IP:
   aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text

3. Connect to Instance:
   ssh -i bird-detection-key.pem ec2-user@YOUR_INSTANCE_IP

4. Run on EC2 Instance:
   sudo yum update -y
   sudo yum install git -y
   git clone YOUR_GITHUB_REPO
   cd FIT5225_A3-ui
   ./deploy-ec2.sh

5. Update Configuration:
   - Copy deployment-config.env to your EC2 instance
   - Update as3_aws/.env with your AWS credentials
   - Restart the application: sudo systemctl restart bird-detection.service

EOF
    
    echo -e "${GREEN}✅ Instructions saved to ec2-setup.txt${NC}"
}

# Main execution
main() {
    check_prerequisites
    deploy_all
}

# Run main function
main "$@" 
