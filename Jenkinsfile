pipeline {
    agent any

    parameters {
        choice(
            name: 'ACTION',
            choices: ['Apply', 'Destroy'],
            description: 'Select Apply to provision infrastructure or Destroy to tear it down.'
        )
    }

    environment {
        VAULT_URL = ''
        TF_DIR   = 'terraform-aws-eks-hashicorp-vault'
    }

    stages {

        stage("Fetch Credentials from Vault") {
            steps {
                script {
                    withCredentials([
                        string(credentialsId: 'VAULT_URL',       variable: 'VAULT_URL'),
                        string(credentialsId: 'vault-role-id',   variable: 'VAULT_ROLE_ID'),
                        string(credentialsId: 'vault-secret-id', variable: 'VAULT_SECRET_ID')
                    ]) {
                        echo "Fetching credentials from Vault..."
                        sh '''
                        export VAULT_ADDR="${VAULT_URL}"

                        echo "Logging into Vault..."
                        VAULT_TOKEN=$(vault write -field=token auth/approle/login \
                            role_id=${VAULT_ROLE_ID} \
                            secret_id=${VAULT_SECRET_ID} || { echo "Vault login failed"; exit 1; })
                        export VAULT_TOKEN=$VAULT_TOKEN

                        echo "Fetching GitHub Token..."
                        GIT_TOKEN=$(vault kv get -field=pat secret/github || { echo "Failed to fetch GitHub token"; exit 1; })

                        echo "Fetching AWS Credentials..."
                        AWS_ACCESS_KEY_ID=$(vault kv get -field=aws_access_key_id aws/terraform-project \
                            || { echo "Failed to fetch AWS Access Key ID"; exit 1; })
                        AWS_SECRET_ACCESS_KEY=$(vault kv get -field=aws_secret_access_key aws/terraform-project \
                            || { echo "Failed to fetch AWS Secret Access Key"; exit 1; })

                        echo "export GIT_TOKEN=${GIT_TOKEN}"             >> vault_env.sh
                        echo "export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}"         >> vault_env.sh
                        echo "export AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}" >> vault_env.sh
                        '''

                        sh '''
                        . ${WORKSPACE}/vault_env.sh
                        echo "Credentials loaded successfully."
                        '''
                    }
                }
            }
        }

        stage("Checkout Source Code") {
            steps {
                echo "Checking out source code from GitHub..."
                sh '''
                git clone https://github.com/cojocloud/terraform-aws-eks-hashicorp-vault.git
                '''
            }
        }

        stage("Install Terraform") {
            steps {
                echo "Installing Terraform..."
                sh '''
                wget -q -O terraform.zip https://releases.hashicorp.com/terraform/1.9.0/terraform_1.9.0_linux_amd64.zip
                unzip -o terraform.zip
                rm -f terraform.zip
                chmod +x terraform
                ./terraform --version
                '''
            }
        }

        stage("Terraform Init") {
            steps {
                echo "Initializing Terraform..."
                sh '''
                . ${WORKSPACE}/vault_env.sh
                cd ${TF_DIR}
                ../terraform init
                '''
            }
        }

        stage("Terraform Plan and Apply") {
            when {
                expression { return params.ACTION == 'Apply' }
            }
            steps {
                echo "Running Terraform Plan and Apply..."
                sh '''
                . ${WORKSPACE}/vault_env.sh
                cd ${TF_DIR}
                ../terraform plan -out=tfplan
                echo "Running Terraform Apply..."
                ../terraform apply -auto-approve tfplan
                echo "Terraform Apply completed successfully."
                '''
            }
        }

        stage("Update Kubeconfig and Verify") {
            when {
                expression { return params.ACTION == 'Apply' }
            }
            steps {
                echo "Updating kubeconfig and verifying cluster..."
                sh '''
                . ${WORKSPACE}/vault_env.sh

                aws sts get-caller-identity || { echo "Invalid AWS credentials"; exit 1; }

                echo "Retrieving EKS cluster name..."
                CLUSTER_NAME=$(aws eks list-clusters --region us-east-1 --query 'clusters[0]' --output text)
                if [ -z "$CLUSTER_NAME" ]; then
                    echo "No EKS cluster found. Exiting..."
                    exit 1
                fi
                echo "EKS Cluster Name: $CLUSTER_NAME"

                KUBE_CONFIG_PATH="/var/lib/jenkins/.kube/config"
                mkdir -p /var/lib/jenkins/.kube
                aws eks update-kubeconfig --name $CLUSTER_NAME --region us-east-1 --kubeconfig $KUBE_CONFIG_PATH
                chown jenkins:jenkins $KUBE_CONFIG_PATH
                chmod 600 $KUBE_CONFIG_PATH

                export KUBECONFIG=$KUBE_CONFIG_PATH
                kubectl get nodes
                kubectl get pods --all-namespaces
                '''
            }
        }

        stage("Terraform Destroy") {
            when {
                expression { return params.ACTION == 'Destroy' }
            }
            steps {
                echo "Running Terraform Destroy..."
                sh '''
                . ${WORKSPACE}/vault_env.sh
                cd ${TF_DIR}
                ../terraform destroy -auto-approve
                '''
            }
        }

    }

    post {
        success {
            echo "Pipeline completed successfully — Action: ${params.ACTION}"
        }
        failure {
            echo "Pipeline failed. Check logs for details."
        }
        always {
            cleanWs()
            echo "Workspace cleaned."
        }
    }
}
