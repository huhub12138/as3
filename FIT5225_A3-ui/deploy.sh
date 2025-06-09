#!/bin/bash

# AWS Bird Detection System Deployment Script
# Usage: ./deploy.sh [bucket-name] [region]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
DEFAULT_REGION="us-east-1"
DEFAULT_BUCKET="bird-detection-$(date +%s)"

# Get parameters
BUCKET_NAME=${1:-$DEFAULT_BUCKET}
REGION=${2:-$DEFAULT_REGION}

echo -e "${BLUE}🚀 Starting AWS Bird Detection System Deployment${NC}"
echo -e "${YELLOW}Bucket Name: $BUCKET_NAME${NC}"
echo -e "${YELLOW}Region: $REGION${NC}"

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo -e "${RED}❌ AWS CLI is not installed. Please install it first.${NC}"
    exit 1
fi

# Check if AWS credentials are configured
if ! aws sts get-caller-identity &> /dev/null; then
    echo -e "${RED}❌ AWS credentials not configured. Please run 'aws configure' first.${NC}"
    exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo -e "${GREEN}✅ AWS Account ID: $ACCOUNT_ID${NC}"

# Function to check if resource exists
check_resource() {
    local resource_type=$1
    local resource_name=$2
    local check_command=$3
    
    echo -e "${BLUE}🔍 Checking if $resource_type '$resource_name' exists...${NC}"
    if eval $check_command &> /dev/null; then
        echo -e "${YELLOW}⚠️  $resource_type '$resource_name' already exists, skipping creation${NC}"
        return 0
    else
        return 1
    fi
}

# Create S3 bucket
echo -e "\n${BLUE}📦 Creating S3 Bucket...${NC}"
if ! check_resource "S3 bucket" "$BUCKET_NAME" "aws s3api head-bucket --bucket $BUCKET_NAME"; then
    aws s3 mb s3://$BUCKET_NAME --region $REGION
    echo -e "${GREEN}✅ S3 bucket created: $BUCKET_NAME${NC}"
    
    # Create folder structure
    aws s3api put-object --bucket $BUCKET_NAME --key images/
    aws s3api put-object --bucket $BUCKET_NAME --key videos/
    aws s3api put-object --bucket $BUCKET_NAME --key audios/
    aws s3api put-object --bucket $BUCKET_NAME --key thumbnails/
    echo -e "${GREEN}✅ Folder structure created${NC}"
    
    # Block public access
    aws s3api put-public-access-block \
        --bucket $BUCKET_NAME \
        --public-access-block-configuration \
        BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
    echo -e "${GREEN}✅ Public access blocked${NC}"
fi

# Create DynamoDB table
echo -e "\n${BLUE}🗄️  Creating DynamoDB Table...${NC}"
TABLE_NAME="bird-detection-media"
if ! check_resource "DynamoDB table" "$TABLE_NAME" "aws dynamodb describe-table --table-name $TABLE_NAME"; then
    aws dynamodb create-table \
        --table-name $TABLE_NAME \
        --attribute-definitions AttributeName=s3-url,AttributeType=S \
        --key-schema AttributeName=s3-url,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST \
        --region $REGION
    
    # Wait for table to be active
    echo -e "${YELLOW}⏳ Waiting for DynamoDB table to be active...${NC}"
    aws dynamodb wait table-exists --table-name $TABLE_NAME
    echo -e "${GREEN}✅ DynamoDB table created: $TABLE_NAME${NC}"
fi

# Create IAM role
echo -e "\n${BLUE}🔐 Creating IAM Role...${NC}"
ROLE_NAME="bird-detection-lambda-role"
if ! check_resource "IAM role" "$ROLE_NAME" "aws iam get-role --role-name $ROLE_NAME"; then
    # Create trust policy
    cat > /tmp/lambda-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

    # Create IAM role
    aws iam create-role \
        --role-name $ROLE_NAME \
        --assume-role-policy-document file:///tmp/lambda-trust-policy.json

    # Create permission policy
    cat > /tmp/lambda-permissions.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogGroup",
                "logs:CreateLogStream",
                "logs:PutLogEvents"
            ],
            "Resource": "arn:aws:logs:*:*:*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject"
            ],
            "Resource": "arn:aws:s3:::$BUCKET_NAME/*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "dynamodb:PutItem",
                "dynamodb:GetItem",
                "dynamodb:UpdateItem",
                "dynamodb:DeleteItem"
            ],
            "Resource": "arn:aws:dynamodb:$REGION:*:table/$TABLE_NAME"
        }
    ]
}
EOF

    # Attach policies
    aws iam put-role-policy \
        --role-name $ROLE_NAME \
        --policy-name bird-detection-lambda-permissions \
        --policy-document file:///tmp/lambda-permissions.json

    aws iam attach-role-policy \
        --role-name $ROLE_NAME \
        --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

    echo -e "${GREEN}✅ IAM role created: $ROLE_NAME${NC}"
    
    # Wait for role to propagate
    echo -e "${YELLOW}⏳ Waiting for IAM role to propagate...${NC}"
    sleep 10
fi

ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME"

# Deploy Upload Lambda Function
echo -e "\n${BLUE}⚡ Deploying Upload Lambda Function...${NC}"
UPLOAD_FUNCTION_NAME="bird-upload-function"
if ! check_resource "Lambda function" "$UPLOAD_FUNCTION_NAME" "aws lambda get-function --function-name $UPLOAD_FUNCTION_NAME"; then
    cd upload_function
    zip -r upload-function.zip . -x "*.git*" "__pycache__/*"
    
    aws lambda create-function \
        --function-name $UPLOAD_FUNCTION_NAME \
        --runtime python3.9 \
        --role $ROLE_ARN \
        --handler upload_lambda.lambda_handler \
        --zip-file fileb://upload-function.zip \
        --timeout 30 \
        --memory-size 128 \
        --environment Variables="{\"S3_BUCKET\":\"$BUCKET_NAME\"}"
    
    rm upload-function.zip
    cd ..
    echo -e "${GREEN}✅ Upload Lambda function deployed${NC}"
fi

# Deploy Audio Detection Lambda Function
echo -e "\n${BLUE}🎵 Deploying Audio Detection Lambda Function...${NC}"
AUDIO_FUNCTION_NAME="bird-audio-detector"
if ! check_resource "Lambda function" "$AUDIO_FUNCTION_NAME" "aws lambda get-function --function-name $AUDIO_FUNCTION_NAME"; then
    cd audio_dectector
    
    # Check if requirements are already installed
    if [ ! -d "package" ]; then
        echo -e "${YELLOW}📦 Installing dependencies for audio detector...${NC}"
        mkdir package
        pip install -r requirements.txt -t package/
    fi
    
    # Copy function code
    cp lambda.py package/
    cp *.tflite package/ 2>/dev/null || echo "No .tflite files found"
    cp *.txt package/ 2>/dev/null || echo "No .txt files found"
    
    # Create deployment package
    cd package
    zip -r ../audio-detector.zip . -x "*.git*" "__pycache__/*"
    cd ..
    
    aws lambda create-function \
        --function-name $AUDIO_FUNCTION_NAME \
        --runtime python3.9 \
        --role $ROLE_ARN \
        --handler lambda.handler \
        --zip-file fileb://audio-detector.zip \
        --timeout 900 \
        --memory-size 3008 \
        --environment Variables="{\"DYNAMODB_TABLE\":\"$TABLE_NAME\"}"
    
    rm audio-detector.zip
    cd ..
    echo -e "${GREEN}✅ Audio detection Lambda function deployed${NC}"
fi

# Deploy Image Detection Lambda Function (if Docker is available)
echo -e "\n${BLUE}🖼️  Deploying Image Detection Lambda Function...${NC}"
IMAGE_FUNCTION_NAME="bird-image-detector"
if command -v docker &> /dev/null; then
    if ! check_resource "Lambda function" "$IMAGE_FUNCTION_NAME" "aws lambda get-function --function-name $IMAGE_FUNCTION_NAME"; then
        cd Img_dectector
        
        # Check if ECR repository exists
        REPO_NAME="bird-image-detector"
        if ! aws ecr describe-repositories --repository-names $REPO_NAME &> /dev/null; then
            aws ecr create-repository --repository-name $REPO_NAME --region $REGION
            echo -e "${GREEN}✅ ECR repository created${NC}"
        fi
        
        # Build and push Docker image
        echo -e "${YELLOW}🔨 Building Docker image...${NC}"
        docker build -t $REPO_NAME .
        
        # Login to ECR
        aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com
        
        # Tag and push
        docker tag $REPO_NAME:latest $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$REPO_NAME:latest
        docker push $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$REPO_NAME:latest
        
        # Create Lambda function
        aws lambda create-function \
            --function-name $IMAGE_FUNCTION_NAME \
            --package-type Image \
            --code ImageUri=$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$REPO_NAME:latest \
            --role $ROLE_ARN \
            --timeout 900 \
            --memory-size 3008 \
            --environment Variables="{\"DYNAMODB_TABLE\":\"$TABLE_NAME\"}"
        
        cd ..
        echo -e "${GREEN}✅ Image detection Lambda function deployed${NC}"
    fi
else
    echo -e "${YELLOW}⚠️  Docker not found. Skipping image detection Lambda deployment.${NC}"
    echo -e "${YELLOW}   You can deploy it manually later using the deployment guide.${NC}"
fi

# Setup S3 Event Triggers
echo -e "\n${BLUE}🔗 Setting up S3 Event Triggers...${NC}"

# Add Lambda permissions for S3
if aws lambda get-policy --function-name $AUDIO_FUNCTION_NAME &> /dev/null; then
    echo -e "${YELLOW}⚠️  S3 trigger permissions already exist for audio function${NC}"
else
    aws lambda add-permission \
        --function-name $AUDIO_FUNCTION_NAME \
        --principal s3.amazonaws.com \
        --action lambda:InvokeFunction \
        --source-arn arn:aws:s3:::$BUCKET_NAME \
        --statement-id s3-trigger-audio
fi

if command -v docker &> /dev/null && aws lambda get-function --function-name $IMAGE_FUNCTION_NAME &> /dev/null; then
    if aws lambda get-policy --function-name $IMAGE_FUNCTION_NAME &> /dev/null; then
        echo -e "${YELLOW}⚠️  S3 trigger permissions already exist for image function${NC}"
    else
        aws lambda add-permission \
            --function-name $IMAGE_FUNCTION_NAME \
            --principal s3.amazonaws.com \
            --action lambda:InvokeFunction \
            --source-arn arn:aws:s3:::$BUCKET_NAME \
            --statement-id s3-trigger-image
    fi
fi

# Create S3 notification configuration
echo -e "${YELLOW}📧 Configuring S3 event notifications...${NC}"
cat > /tmp/s3-notification.json << EOF
{
    "LambdaConfigurations": [
        {
            "Id": "AudioTrigger",
            "LambdaFunctionArn": "arn:aws:lambda:$REGION:$ACCOUNT_ID:function:$AUDIO_FUNCTION_NAME",
            "Events": ["s3:ObjectCreated:*"],
            "Filter": {
                "Key": {
                    "FilterRules": [
                        {
                            "Name": "prefix",
                            "Value": "audios/"
                        }
                    ]
                }
            }
        }
EOF

if command -v docker &> /dev/null && aws lambda get-function --function-name $IMAGE_FUNCTION_NAME &> /dev/null; then
    cat >> /tmp/s3-notification.json << EOF
        ,{
            "Id": "ImageVideoTrigger",
            "LambdaFunctionArn": "arn:aws:lambda:$REGION:$ACCOUNT_ID:function:$IMAGE_FUNCTION_NAME",
            "Events": ["s3:ObjectCreated:*"],
            "Filter": {
                "Key": {
                    "FilterRules": [
                        {
                            "Name": "prefix",
                            "Value": "images/"
                        }
                    ]
                }
            }
        }
EOF
fi

cat >> /tmp/s3-notification.json << EOF
    ]
}
EOF

aws s3api put-bucket-notification-configuration \
    --bucket $BUCKET_NAME \
    --notification-configuration file:///tmp/s3-notification.json

echo -e "${GREEN}✅ S3 event triggers configured${NC}"

# Generate environment configuration
echo -e "\n${BLUE}📝 Generating environment configuration...${NC}"
UPLOAD_LAMBDA_ARN="arn:aws:lambda:$REGION:$ACCOUNT_ID:function:$UPLOAD_FUNCTION_NAME"
AUDIO_LAMBDA_ARN="arn:aws:lambda:$REGION:$ACCOUNT_ID:function:$AUDIO_FUNCTION_NAME"
IMAGE_LAMBDA_ARN="arn:aws:lambda:$REGION:$ACCOUNT_ID:function:$IMAGE_FUNCTION_NAME"

cat > deployment-config.env << EOF
# AWS Configuration for Bird Detection System
AWS_DEFAULT_REGION=$REGION
AWS_S3_BUCKET=$BUCKET_NAME
DYNAMODB_TABLE=$TABLE_NAME

# Lambda Function ARNs
UPLOAD_LAMBDA_ARN=$UPLOAD_LAMBDA_ARN
AUDIO_DETECTOR_ARN=$AUDIO_LAMBDA_ARN
IMAGE_DETECTOR_ARN=$IMAGE_LAMBDA_ARN

# Flask Configuration
SECRET_KEY=$(openssl rand -hex 32)
DATABASE_URL=sqlite:///app.db
EOF

echo -e "${GREEN}✅ Configuration saved to deployment-config.env${NC}"

# Test deployment
echo -e "\n${BLUE}🧪 Testing deployment...${NC}"

# Test upload function
echo -e "${YELLOW}Testing upload function...${NC}"
aws lambda invoke \
    --function-name $UPLOAD_FUNCTION_NAME \
    --payload '{"body": "{\"type\":\"images\",\"suffix\":\"jpg\"}"}' \
    /tmp/test-response.json

if grep -q "statusCode.*200" /tmp/test-response.json; then
    echo -e "${GREEN}✅ Upload function test passed${NC}"
else
    echo -e "${RED}❌ Upload function test failed${NC}"
    cat /tmp/test-response.json
fi

# Clean up temporary files
rm -f /tmp/lambda-trust-policy.json /tmp/lambda-permissions.json /tmp/s3-notification.json /tmp/test-response.json

echo -e "\n${GREEN}🎉 Deployment completed successfully!${NC}"
echo -e "\n${BLUE}📋 Deployment Summary:${NC}"
echo -e "  S3 Bucket: ${GREEN}$BUCKET_NAME${NC}"
echo -e "  DynamoDB Table: ${GREEN}$TABLE_NAME${NC}"
echo -e "  Upload Function: ${GREEN}$UPLOAD_FUNCTION_NAME${NC}"
echo -e "  Audio Function: ${GREEN}$AUDIO_FUNCTION_NAME${NC}"
if command -v docker &> /dev/null && aws lambda get-function --function-name $IMAGE_FUNCTION_NAME &> /dev/null; then
    echo -e "  Image Function: ${GREEN}$IMAGE_FUNCTION_NAME${NC}"
fi

echo -e "\n${BLUE}🚀 Next Steps:${NC}"
echo -e "1. Update as3_aws/config.py with the values from deployment-config.env"
echo -e "2. Deploy your Flask application to EC2 or App Runner"
echo -e "3. Test the complete system with file uploads"

echo -e "\n${YELLOW}💡 Configuration file created: deployment-config.env${NC}"
echo -e "${YELLOW}   Copy these values to your Flask application configuration${NC}" 