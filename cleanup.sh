#!/bin/bash

# retrieve the service network id
SERVICE_NETWORK_ID=$( aws vpc-lattice list-service-networks | jq -r '.items[0].id' )

# select the frontend cluster
CLUSTER_CONTEXT=$( kubectl config get-contexts --no-headers | \
    grep lattice-frontend | sed 's/ [ ]*/ /g' | cut -f 2 -d ' ' )
kubectl config use-context $CLUSTER_CONTEXT

# delete the service associations
kubectl delete -f lattice-frontend-route.yaml

# retrieve the cluster VPC id
CLUSTER_VPC_ID=$( eksctl get cluster lattice-frontend -o json | jq -r '.[].ResourcesVpcConfig.VpcId' )

# delete the service network association
SNVA=$( aws vpc-lattice list-service-network-vpc-associations --vpc-identifier $CLUSTER_VPC_ID | jq -r '.items[0].id' )
aws vpc-lattice delete-service-network-vpc-association \
    --service-network-vpc-association-identifier $SNVA

# select the backend cluster
CLUSTER_CONTEXT=$( kubectl config get-contexts --no-headers | \
    grep lattice-backend | sed 's/ [ ]*/ /g' | cut -f 2 -d ' ' )
kubectl config use-context $CLUSTER_CONTEXT

# delete the service associations
kubectl delete -f lattice-backend-route.yaml

# retrieve the cluster VPC id
CLUSTER_VPC_ID=$( eksctl get cluster lattice-backend -o json | jq -r '.[].ResourcesVpcConfig.VpcId' )

# delete the service network association
SNVA=$( aws vpc-lattice list-service-network-vpc-associations --vpc-identifier $CLUSTER_VPC_ID | jq -r '.items[0].id' )
aws vpc-lattice delete-service-network-vpc-association \
    --service-network-vpc-association-identifier $SNVA

# delete the sercvice network
aws vpc-lattice delete-service-network --service-network-identifier $SERVICE_NETWORK_ID

# delete the clusters
eksctl delete cluster --name=lattice-frontend
eksctl delete cluster --name=lattice-backend

# delete the IAM policy
export VPCLatticeControllerIAMPolicyArn=$(aws iam list-policies --query 'Policies[?PolicyName==`VPCLatticeControllerIAMPolicy`].Arn' --output text)
aws iam delete-policy --policy-arn $VPCLatticeControllerIAMPolicyArn