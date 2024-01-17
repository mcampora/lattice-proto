#!/bin/bash

# in interactive shells, run the following command to support comments
# set -o INTERACTIVE_COMMENTS

#------------------------------------------------------------------------------
# 0/ globals
#------------------------------------------------------------------------------
# define your AWS credentials beforehand
export AWS_REGION=us-east-1
export AWS_ACCOUNT_ID=$( aws sts get-caller-identity --query "Account" --output text )
export ECR_REPO=$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
export LOG_LEVEL=info
export DEFAULT_SERVICE_NETWORK=lattice-proto
export ENABLE_SERVICE_NETWORK_OVERRIDE=""

#------------------------------------------------------------------------------
# 1/ create the clusters and deploy the Lattice plugin
#------------------------------------------------------------------------------
create_cluster() {
    CLUSTER_NAME=$1

    # create the EKS cluster
    eksctl create cluster --name=$CLUSTER_NAME --zones=us-east-1a,us-east-1b,us-east-1d

    # make sure the cluster we just created is the default one for kubectl
    CLUSTER_CONTEXT=$( kubectl config get-contexts --no-headers | grep $CLUSTER_NAME | sed 's/ [ ]*/ /g' | cut -f 2 -d ' ' )
    kubectl config use-context $CLUSTER_CONTEXT

    # Configure security group to allow all Pods communicating with VPC Lattice
    CLUSTER_SG=$(aws eks describe-cluster --name $CLUSTER_NAME --output json| jq -r '.cluster.resourcesVpcConfig.clusterSecurityGroupId')
    PREFIX_LIST_ID=$(aws ec2 describe-managed-prefix-lists --query "PrefixLists[?PrefixListName=="\'com.amazonaws.$AWS_REGION.vpc-lattice\'"].PrefixListId" | jq -r '.[]')
    aws ec2 authorize-security-group-ingress --group-id $CLUSTER_SG --ip-permissions "PrefixListIds=[{PrefixListId=${PREFIX_LIST_ID}}],IpProtocol=-1"
    PREFIX_LIST_ID_IPV6=$(aws ec2 describe-managed-prefix-lists --query "PrefixLists[?PrefixListName=="\'com.amazonaws.$AWS_REGION.ipv6.vpc-lattice\'"].PrefixListId" | jq -r '.[]')
    aws ec2 authorize-security-group-ingress --group-id $CLUSTER_SG --ip-permissions "PrefixListIds=[{PrefixListId=${PREFIX_LIST_ID_IPV6}}],IpProtocol=-1"

    # Create an IAM OIDC provider
    eksctl utils associate-iam-oidc-provider --cluster $CLUSTER_NAME --approve --region $AWS_REGION

    # Create an IAM policy for the Lattice plugin
    # !!! will fail without consequence for the second cluster, I should add a [if it does not exist] !!!
    aws iam create-policy \
        --policy-name VPCLatticeControllerIAMPolicy \
        --policy-document file://lattice-policy.json

    # Create the aws-application-networking-system namespace
    kubectl apply -f lattice-namespace.yaml

    ## Create an iamserviceaccount for pod level permission
    export VPCLatticeControllerIAMPolicyArn=$(aws iam list-policies --query 'Policies[?PolicyName==`VPCLatticeControllerIAMPolicy`].Arn' --output text)
    eksctl create iamserviceaccount \
        --cluster=$CLUSTER_NAME \
        --namespace=aws-application-networking-system \
        --name=gateway-api-controller \
        --attach-policy-arn=$VPCLatticeControllerIAMPolicyArn \
        --override-existing-serviceaccounts \
        --region $AWS_REGION \
        --approve

    ## Deploy the Lattice controller
    kubectl apply -f lattice-controller.yaml

    ## Deploy the Lattice Gateway class
    kubectl apply -f lattice-gatewayclass.yaml

    ## Deploy the Lattice Gateway
    kubectl apply -f lattice-gateway.yaml

    ## Deploy a parking container so we can execute commands from within the cluster
    ## This allows to skip the deployment of a proper ingress controller
    kubectl apply -f parking.yaml
}

# Create the 2 clusters used with the prototype
create_cluster lattice-backend
create_cluster lattice-frontend

#------------------------------------------------------------------------------
# 2/ create a Lattice service network
#------------------------------------------------------------------------------
export SERVICE_NETWORK_ID=$( aws vpc-lattice create-service-network --name $DEFAULT_SERVICE_NETWORK | jq -r '.id' )

#------------------------------------------------------------------------------
# 3/ build, push and deploy the services, expose them with Lattice
#------------------------------------------------------------------------------
deploy_service() {
    SERVICE_NETWORK_ID=$1
    CLUSTER_NAME=$2
    SERVICE_NAME=$3
    IMAGE=$3

    # create an ECR repo and authenticate the terminal
    aws ecr create-repository --repository-name $IMAGE
    aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REPO

    # build the backend image
    pushd ./$IMAGE
    ./build.sh
    popd

    # push the image to ECR
    docker tag ${IMAGE}:latest $ECR_REPO/${IMAGE}:latest
    docker push $ECR_REPO/${IMAGE}:latest

    # select the right cluster
    CLUSTER_CONTEXT=$( kubectl config get-contexts --no-headers | grep $CLUSTER_NAME | sed 's/ [ ]*/ /g' | cut -f 2 -d ' ' )
    kubectl config use-context $CLUSTER_CONTEXT

    # deploy the service
    # use envsubst to inject the repo name in the yaml file
    envsubst < eks-${IMAGE}.yaml | kubectl apply -f -

    # get the cluster VPC id
    CLUSTER_VPC_ID=$( eksctl get cluster $CLUSTER_NAME -o json | jq -r '.[].ResourcesVpcConfig.VpcId' )

    # associate the Lattice network with the cluster VPC
    aws vpc-lattice create-service-network-vpc-association --service-network-identifier $SERVICE_NETWORK_ID --vpc-identifier $CLUSTER_VPC_ID

    # create a route for the service it will automatically 
    # create a service association with the Lattice network
    kubectl apply -f lattice-$SERVICE_NAME-route.yaml

    # to test the service without Lattice
    # kubectl port-forward service/backend-v1-svc 8080:80
    # curl http://localhost:8080

    # to test the service with minikube
    # eval $(minikube docker-env)
    # minikube start
    # ...deploy the service...
    # minikube service backend-v1-svc
}

# Deploy the 2backend in its cluster
deploy_service $SERVICE_NETWORK_ID lattice-backend backend

# get the backend URL and set it as an environment variable
# so we can infect it as a parameter in the frontend deployment
export BACKEND_URL=$(kubectl get httproute $SERVICE_NAME-route -o json | jq -r '.metadata.annotations."application-networking.k8s.aws/lattice-assigned-domain-name"')
echo $BACKEND_URL

deploy_service $SERVICE_NETWORK_ID lattice-frontend frontend

#------------------------------------------------------------------------------
# test the services, demonstrate the use of the Lattice network, 
# one hop and two hops
#------------------------------------------------------------------------------
test_service() {
    CLUSTER_NAME=$1
    SERVICE_NAME=$2

    # select the right cluster
    CLUSTER_CONTEXT=$( kubectl config get-contexts --no-headers | grep $CLUSTER_NAME | sed 's/ [ ]*/ /g' | cut -f 2 -d ' ' )
    kubectl config use-context $CLUSTER_CONTEXT

    # retrieve the assigned domain name
    FQDN=$(kubectl get httproute $SERVICE_NAME-route -o json | jq -r '.metadata.annotations."application-networking.k8s.aws/lattice-assigned-domain-name"')

    # use the parking container to test the service
    kubectl exec deploy/parking -- curl $FQDN/live
}

test_service lattice-backend backend
test_service lattice-frontend frontend


