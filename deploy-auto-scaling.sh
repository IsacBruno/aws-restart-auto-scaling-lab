#!/bin/bash
#
# deploy-auto-scaling.sh
#
# Script que criei para automatizar o processo do lab de Auto Scaling na AWS.
# A ideia aqui foi pegar os comandos que rodei manualmente durante o lab e
# organizar tudo em um script único, com validações básicas e mensagens de
# status, pra ficar mais fácil de reexecutar o ambiente sem precisar repetir
# passo a passo pelo console ou digitar comando por comando.
#
# Pré-requisitos:
#   - AWS CLI instalada e configurada (aws configure)
#   - Permissões para EC2, Auto Scaling, ELB e CloudWatch
#   - Um Key Pair, Security Group e Subnets já existentes no VPC
#
# Uso:
#   ./deploy-auto-scaling.sh
#

set -e  # Para o script se algum comando falhar

# ---------------------------------------------------------
# Variáveis de configuração
# ---------------------------------------------------------
# Ajustei essas variáveis para os valores usados no ambiente do lab.
# Em um cenário real eu moveria isso para um arquivo .env separado.

KEY_NAME="vockey"
INSTANCE_TYPE="t3.micro"
AMI_ID=""                     # AMI base da região (preencher antes de rodar)
SECURITY_GROUP_ID=""          # ID do security group HTTPAccess
SUBNET_ID=""                  # Subnet pública usada para a instância inicial
VPC_ID=""                     # ID do Lab VPC
PRIVATE_SUBNET_1=""           # Private Subnet 1
PRIVATE_SUBNET_2=""           # Private Subnet 2
PUBLIC_SUBNET_1=""            # Public Subnet 1
PUBLIC_SUBNET_2=""            # Public Subnet 2

USER_DATA_FILE="./UserData.txt"
AMI_NAME="WebServerAMI"
LAUNCH_TEMPLATE_NAME="web-app-launch-template"
ASG_NAME="Web App Auto Scaling Group"
ALB_NAME="WebServerELB"
TARGET_GROUP_NAME="webserver-app"

REGION=$(aws configure get region)

# ---------------------------------------------------------
# Funções auxiliares
# ---------------------------------------------------------

log() {
    echo -e "\n>>> $1\n"
}

check_var() {
    # Confere se uma variável obrigatória foi preenchida antes de continuar.
    # Escrevi isso depois de esquecer de preencher o SUBNET_ID na primeira
    # tentativa e o script quebrar lá na frente sem uma mensagem clara.
    if [ -z "${!1}" ]; then
        echo "Erro: a variável $1 não foi definida. Edite o script antes de rodar."
        exit 1
    fi
}

wait_for_instance() {
    local instance_id=$1
    log "Aguardando a instância $instance_id ficar em estado 'running'..."
    aws ec2 wait instance-running --instance-ids "$instance_id"
    log "Instância $instance_id está rodando."
}

# ---------------------------------------------------------
# Etapa 1: Criar a instância base que vai virar a AMI
# ---------------------------------------------------------

create_base_instance() {
    check_var "AMI_ID"
    check_var "SECURITY_GROUP_ID"
    check_var "SUBNET_ID"

    log "Criando instância EC2 base para gerar a AMI..."

    INSTANCE_ID=$(aws ec2 run-instances \
        --key-name "$KEY_NAME" \
        --instance-type "$INSTANCE_TYPE" \
        --image-id "$AMI_ID" \
        --user-data "file://$USER_DATA_FILE" \
        --security-group-ids "$SECURITY_GROUP_ID" \
        --subnet-id "$SUBNET_ID" \
        --associate-public-ip-address \
        --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=WebServer}]' \
        --output text \
        --query 'Instances[0].InstanceId')

    log "Instância criada: $INSTANCE_ID"

    wait_for_instance "$INSTANCE_ID"

    PUBLIC_DNS=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PublicDnsName' \
        --output text)

    log "DNS público da instância: $PUBLIC_DNS"
    log "Aguarde alguns minutos para o servidor web inicializar antes de testar em http://$PUBLIC_DNS/index.php"
}

# ---------------------------------------------------------
# Etapa 2: Criar a AMI a partir da instância base
# ---------------------------------------------------------

create_ami() {
    check_var "INSTANCE_ID"

    log "Criando AMI '$AMI_NAME' a partir da instância $INSTANCE_ID..."

    NEW_AMI_ID=$(aws ec2 create-image \
        --name "$AMI_NAME" \
        --instance-id "$INSTANCE_ID" \
        --output text \
        --query 'ImageId')

    log "AMI criada: $NEW_AMI_ID"
    log "Aguardando a AMI ficar disponível (isso pode levar alguns minutos)..."

    aws ec2 wait image-available --image-ids "$NEW_AMI_ID"

    log "AMI $NEW_AMI_ID disponível para uso."
}

# ---------------------------------------------------------
# Etapa 3: Criar o Application Load Balancer e o Target Group
# ---------------------------------------------------------

create_load_balancer() {
    check_var "VPC_ID"
    check_var "SECURITY_GROUP_ID"
    check_var "PUBLIC_SUBNET_1"
    check_var "PUBLIC_SUBNET_2"

    log "Criando target group '$TARGET_GROUP_NAME'..."

    TARGET_GROUP_ARN=$(aws elbv2 create-target-group \
        --name "$TARGET_GROUP_NAME" \
        --protocol HTTP \
        --port 80 \
        --vpc-id "$VPC_ID" \
        --health-check-path "/index.php" \
        --target-type instance \
        --output text \
        --query 'TargetGroups[0].TargetGroupArn')

    log "Target group criado: $TARGET_GROUP_ARN"

    log "Criando o Application Load Balancer '$ALB_NAME'..."

    ALB_ARN=$(aws elbv2 create-load-balancer \
        --name "$ALB_NAME" \
        --subnets "$PUBLIC_SUBNET_1" "$PUBLIC_SUBNET_2" \
        --security-groups "$SECURITY_GROUP_ID" \
        --output text \
        --query 'LoadBalancers[0].LoadBalancerArn')

    ALB_DNS=$(aws elbv2 describe-load-balancers \
        --load-balancer-arns "$ALB_ARN" \
        --output text \
        --query 'LoadBalancers[0].DNSName')

    log "Load Balancer criado. DNS: $ALB_DNS"

    log "Criando listener na porta 80 apontando para o target group..."

    aws elbv2 create-listener \
        --load-balancer-arn "$ALB_ARN" \
        --protocol HTTP \
        --port 80 \
        --default-actions Type=forward,TargetGroupArn="$TARGET_GROUP_ARN" > /dev/null

    log "Listener configurado com sucesso."
}

# ---------------------------------------------------------
# Etapa 4: Criar o Launch Template
# ---------------------------------------------------------

create_launch_template() {
    check_var "NEW_AMI_ID"
    check_var "SECURITY_GROUP_ID"

    log "Criando launch template '$LAUNCH_TEMPLATE_NAME'..."

    LAUNCH_TEMPLATE_ID=$(aws ec2 create-launch-template \
        --launch-template-name "$LAUNCH_TEMPLATE_NAME" \
        --version-description "A web server for the load test app" \
        --launch-template-data "{
            \"ImageId\": \"$NEW_AMI_ID\",
            \"InstanceType\": \"$INSTANCE_TYPE\",
            \"SecurityGroupIds\": [\"$SECURITY_GROUP_ID\"]
        }" \
        --output text \
        --query 'LaunchTemplate.LaunchTemplateId')

    log "Launch template criado: $LAUNCH_TEMPLATE_ID"
}

# ---------------------------------------------------------
# Etapa 5: Criar o Auto Scaling Group
# ---------------------------------------------------------

create_auto_scaling_group() {
    check_var "LAUNCH_TEMPLATE_ID"
    check_var "TARGET_GROUP_ARN"
    check_var "PRIVATE_SUBNET_1"
    check_var "PRIVATE_SUBNET_2"

    log "Criando Auto Scaling Group '$ASG_NAME'..."

    aws autoscaling create-auto-scaling-group \
        --auto-scaling-group-name "$ASG_NAME" \
        --launch-template "LaunchTemplateId=$LAUNCH_TEMPLATE_ID,Version='\$Latest'" \
        --min-size 2 \
        --max-size 4 \
        --desired-capacity 2 \
        --target-group-arns "$TARGET_GROUP_ARN" \
        --vpc-zone-identifier "$PRIVATE_SUBNET_1,$PRIVATE_SUBNET_2" \
        --health-check-type ELB \
        --health-check-grace-period 120 \
        --tags "Key=Name,Value=WebApp,PropagateAtLaunch=true"

    log "Auto Scaling Group criado com capacidade mínima 2 e máxima 4."

    log "Configurando política de scaling por CPU média (target tracking, 50%)..."

    aws autoscaling put-scaling-policy \
        --auto-scaling-group-name "$ASG_NAME" \
        --policy-name "cpu-target-tracking-50" \
        --policy-type "TargetTrackingScaling" \
        --target-tracking-configuration '{
            "PredefinedMetricSpecification": {
                "PredefinedMetricType": "ASGAverageCPUUtilization"
            },
            "TargetValue": 50.0
        }' > /dev/null

    log "Política de scaling configurada."
}

# ---------------------------------------------------------
# Etapa 6: Verificar o status do ambiente
# ---------------------------------------------------------

check_status() {
    log "Verificando instâncias do Auto Scaling Group..."

    aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "$ASG_NAME" \
        --query 'AutoScalingGroups[0].Instances[*].[InstanceId,LifecycleState,HealthStatus]' \
        --output table

    log "Verificando saúde dos targets no Load Balancer..."

    aws elbv2 describe-target-health \
        --target-group-arn "$TARGET_GROUP_ARN" \
        --query 'TargetHealthDescriptions[*].[Target.Id,TargetHealth.State]' \
        --output table
}

# ---------------------------------------------------------
# Execução principal
# ---------------------------------------------------------

main() {
    log "Iniciando deploy do ambiente de Auto Scaling na região $REGION"

    create_base_instance
    create_ami
    create_load_balancer
    create_launch_template
    create_auto_scaling_group

    log "Aguardando 60 segundos para as instâncias do ASG iniciarem..."
    sleep 60

    check_status

    log "Deploy finalizado."
    log "Acesse a aplicação em: http://$ALB_DNS"
    log "Use o botão 'Start Stress' na página para testar o scale-out automático."
}

main
