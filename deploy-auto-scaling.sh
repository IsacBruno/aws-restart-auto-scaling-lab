#!/bin/bash
# A linha acima (shebang) diz ao sistema que esse arquivo deve ser executado
# usando o interpretador bash, mesmo que ele seja chamado sem o comando "bash" na frente.

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

set -e
# "set -e" faz o script parar imediatamente se qualquer comando retornar
# um erro. Sem isso, se um passo falhasse (por exemplo, criar a instância),
# o script continuaria tentando executar os próximos comandos mesmo sem
# a instância existir, e os erros ficariam confusos de rastrear.

# ---------------------------------------------------------
# Variáveis de configuração
# ---------------------------------------------------------
# Ajustei essas variáveis para os valores usados no ambiente do lab.
# Em um cenário real eu moveria isso para um arquivo .env separado.

KEY_NAME="vockey"
# Nome do par de chaves (Key Pair) usado para acessar a instância via SSH.
# No ambiente do lab, o par de chaves já vem criado com esse nome padrão.

INSTANCE_TYPE="t3.micro"
# Tipo da instância EC2. t3.micro é uma instância pequena, geralmente
# elegível para o free tier, suficiente para rodar o servidor web do lab.

AMI_ID=""
# ID da imagem base da AWS usada para criar a primeira instância.
# Precisa ser preenchido manualmente com o ID correspondente à região
# em que o lab está sendo executado.
                     # AMI base da região (preencher antes de rodar)

SECURITY_GROUP_ID=""
# ID do Security Group que libera a porta HTTP (80) para acesso externo.
# Esse grupo já é criado automaticamente pelo ambiente do lab.
          # ID do security group HTTPAccess

SUBNET_ID=""
# Subnet onde a instância base (usada para gerar a AMI) vai ser lançada.
# Precisa ser uma subnet pública, já que essa instância recebe IP público.
          # Subnet pública usada para a instância inicial

VPC_ID=""
# ID do VPC (rede virtual) do ambiente do lab. É usado na criação
# do Target Group e do Load Balancer, que precisam saber em qual rede operar.
                     # ID do Lab VPC

PRIVATE_SUBNET_1=""
# Primeira subnet privada, usada para lançar as instâncias do
# Auto Scaling Group. Fica isolada de acesso direto da internet.
           # Private Subnet 1

PRIVATE_SUBNET_2=""
# Segunda subnet privada, em uma zona de disponibilidade diferente da
# primeira. Ter duas subnets em zonas distintas é o que garante que o
# ambiente continue funcionando mesmo se uma zona da AWS cair.
           # Private Subnet 2

PUBLIC_SUBNET_1=""
# Primeira subnet pública, usada pelo Load Balancer para receber tráfego
# vindo da internet.
            # Public Subnet 1

PUBLIC_SUBNET_2=""
# Segunda subnet pública, também usada pelo Load Balancer, em outra
# zona de disponibilidade — mesmo motivo das subnets privadas.
            # Public Subnet 2

USER_DATA_FILE="./UserData.txt"
# Caminho do script de inicialização que será executado automaticamente
# assim que a instância EC2 subir. É esse script que instala o servidor
# web e a aplicação PHP usada para simular carga de CPU.

AMI_NAME="WebServerAMI"
# Nome que será dado à AMI criada a partir da instância base.
# Esse nome é só um identificador dentro da sua conta AWS.

LAUNCH_TEMPLATE_NAME="web-app-launch-template"
# Nome do Launch Template, que funciona como o "molde" usado pelo
# Auto Scaling Group toda vez que precisa criar uma nova instância.

ASG_NAME="Web App Auto Scaling Group"
# Nome do Auto Scaling Group que será criado.

ALB_NAME="WebServerELB"
# Nome do Application Load Balancer, responsável por distribuir as
# requisições entre as instâncias saudáveis do Auto Scaling Group.

TARGET_GROUP_NAME="webserver-app"
# Nome do Target Group, que é a lista de instâncias que o Load Balancer
# monitora e para onde ele encaminha o tráfego.

REGION=$(aws configure get region)
# Pega a região configurada atualmente na AWS CLI (com "aws configure")
# e guarda na variável REGION, só para exibir depois nas mensagens de log.

# ---------------------------------------------------------
# Funções auxiliares
# ---------------------------------------------------------

log() {
    echo -e "\n>>> $1\n"
}
# Função simples para exibir mensagens de status durante a execução.
# Em vez de espalhar "echo" solto pelo script, centralizei aqui para
# manter um formato padronizado (linha em branco antes e depois, e o
# prefixo ">>>" pra destacar visualmente cada etapa no terminal).

check_var() {
    # Confere se uma variável obrigatória foi preenchida antes de continuar.
    # Escrevi isso depois de esquecer de preencher o SUBNET_ID na primeira
    # tentativa e o script quebrar lá na frente sem uma mensagem clara.
    if [ -z "${!1}" ]; then
        echo "Erro: a variável $1 não foi definida. Edite o script antes de rodar."
        exit 1
    fi
}
# "$1" aqui é o nome da variável passado como texto (ex: check_var "AMI_ID").
# "${!1}" é uma indireção do bash: ele pega o valor da variável cujo nome
# está guardado em $1. Ou seja, se eu chamar check_var "AMI_ID", o bash
# vai olhar o conteúdo da variável AMI_ID, não o texto "AMI_ID" em si.
# Se estiver vazia ("-z"), o script imprime o erro e encerra com "exit 1".

wait_for_instance() {
    local instance_id=$1
    log "Aguardando a instância $instance_id ficar em estado 'running'..."
    aws ec2 wait instance-running --instance-ids "$instance_id"
    log "Instância $instance_id está rodando."
}
# Função que usa o comando "aws ec2 wait instance-running", que fica
# checando periodicamente o status da instância até ela realmente estar
# no estado "running". Isso evita que o script siga para os próximos
# passos antes da instância estar pronta para uso.
# "local instance_id" cria uma variável que só existe dentro dessa função,
# evitando conflito com outras variáveis do script.

# ---------------------------------------------------------
# Etapa 1: Criar a instância base que vai virar a AMI
# ---------------------------------------------------------

create_base_instance() {
    check_var "AMI_ID"
    check_var "SECURITY_GROUP_ID"
    check_var "SUBNET_ID"
    # Antes de tentar criar a instância, confirmo que as três variáveis
    # essenciais para esse passo foram preenchidas.

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
    # Esse comando cria a instância EC2. Os parâmetros definem:
    # - qual chave usar para acesso (--key-name)
    # - o tipo de instância (--instance-type)
    # - a imagem base (--image-id)
    # - o script de inicialização (--user-data)
    # - o grupo de segurança que libera a porta HTTP (--security-group-ids)
    # - a subnet onde ela vai subir (--subnet-id)
    # - que ela deve receber um IP público (--associate-public-ip-address)
    # - uma tag "Name=WebServer" para identificar depois no console
    # "--query" filtra a resposta da AWS pra pegar só o InstanceId,
    # e "--output text" tira as aspas e formatação JSON, deixando o
    # valor pronto para ser usado direto na variável INSTANCE_ID.

    log "Instância criada: $INSTANCE_ID"

    wait_for_instance "$INSTANCE_ID"
    # Chama a função criada antes para esperar a instância ficar "running".

    PUBLIC_DNS=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PublicDnsName' \
        --output text)
    # Consulta os detalhes da instância recém-criada e extrai o endereço
    # DNS público dela, que é o que permite acessar o servidor web pelo navegador.

    log "DNS público da instância: $PUBLIC_DNS"
    log "Aguarde alguns minutos para o servidor web inicializar antes de testar em http://$PUBLIC_DNS/index.php"
    # Aviso importante: mesmo com a instância "running", o script de
    # inicialização (UserData) ainda leva um tempo para instalar o
    # servidor web, então a aplicação não fica disponível instantaneamente.
}

# ---------------------------------------------------------
# Etapa 2: Criar a AMI a partir da instância base
# ---------------------------------------------------------

create_ami() {
    check_var "INSTANCE_ID"
    # Confirma que a instância base já foi criada antes de tentar gerar a AMI.

    log "Criando AMI '$AMI_NAME' a partir da instância $INSTANCE_ID..."

    NEW_AMI_ID=$(aws ec2 create-image \
        --name "$AMI_NAME" \
        --instance-id "$INSTANCE_ID" \
        --output text \
        --query 'ImageId')
    # Cria uma nova AMI usando a instância como base. Por padrão, a AWS
    # reinicia a instância antes de tirar essa "foto" do sistema, para
    # garantir que o disco esteja em um estado consistente.
    # O ID da nova imagem gerada é guardado em NEW_AMI_ID.

    log "AMI criada: $NEW_AMI_ID"
    log "Aguardando a AMI ficar disponível (isso pode levar alguns minutos)..."

    aws ec2 wait image-available --image-ids "$NEW_AMI_ID"
    # Assim como o "wait instance-running", esse comando fica checando o
    # status da AMI até ela sair do estado "pending" e ficar "available",
    # ou seja, pronta para ser usada em novas instâncias.

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
    # Confirma que os IDs de rede necessários para o Load Balancer existem.

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
    # O Target Group é a lista de instâncias que o Load Balancer vai
    # monitorar. Aqui defino que ele vai checar a saúde das instâncias
    # acessando o caminho "/index.php" na porta 80 — se essa página
    # não responder, a instância é marcada como "unhealthy" e para de
    # receber tráfego. O ARN (identificador único do recurso) é salvo
    # na variável TARGET_GROUP_ARN pra usar mais adiante.

    log "Target group criado: $TARGET_GROUP_ARN"

    log "Criando o Application Load Balancer '$ALB_NAME'..."

    ALB_ARN=$(aws elbv2 create-load-balancer \
        --name "$ALB_NAME" \
        --subnets "$PUBLIC_SUBNET_1" "$PUBLIC_SUBNET_2" \
        --security-groups "$SECURITY_GROUP_ID" \
        --output text \
        --query 'LoadBalancers[0].LoadBalancerArn')
    # Cria o Load Balancer, associando ele às duas subnets públicas
    # (para operar nas duas zonas de disponibilidade) e ao security
    # group que libera a porta HTTP.

    ALB_DNS=$(aws elbv2 describe-load-balancers \
        --load-balancer-arns "$ALB_ARN" \
        --output text \
        --query 'LoadBalancers[0].DNSName')
    # Recupera o endereço DNS do Load Balancer recém-criado, que é o
    # link que será usado para acessar a aplicação de fora.

    log "Load Balancer criado. DNS: $ALB_DNS"

    log "Criando listener na porta 80 apontando para o target group..."

    aws elbv2 create-listener \
        --load-balancer-arn "$ALB_ARN" \
        --protocol HTTP \
        --port 80 \
        --default-actions Type=forward,TargetGroupArn="$TARGET_GROUP_ARN" > /dev/null
    # O listener é a "porta de entrada" do Load Balancer: define que
    # todo tráfego HTTP recebido na porta 80 deve ser encaminhado
    # (forward) para o Target Group criado anteriormente.
    # O "> /dev/null" só descarta a saída padrão do comando no terminal,
    # já que não preciso guardar nenhum valor retornado por ele.

    log "Listener configurado com sucesso."
}

# ---------------------------------------------------------
# Etapa 4: Criar o Launch Template
# ---------------------------------------------------------

create_launch_template() {
    check_var "NEW_AMI_ID"
    check_var "SECURITY_GROUP_ID"
    # Confirma que a AMI já existe e que o security group foi informado.

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
    # O "--launch-template-data" recebe um JSON descrevendo como cada
    # nova instância deve ser criada: qual imagem usar (a AMI que
    # acabamos de gerar), o tipo de instância e o security group.
    # É esse template que o Auto Scaling Group vai usar como referência
    # sempre que precisar subir uma instância nova.

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
    # Confirma que todas as dependências (template, target group e
    # subnets privadas) já foram criadas antes de montar o grupo.

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
    # Aqui é onde o Auto Scaling Group é montado de fato:
    # - "--launch-template" com "Version=$Latest" diz para sempre usar
    #   a versão mais recente do template, mesmo que ele seja atualizado depois.
    # - "--min-size 2 / --max-size 4 / --desired-capacity 2" definem os
    #   limites: nunca menos de 2 instâncias, nunca mais de 4, começando com 2.
    # - "--target-group-arns" conecta o grupo ao Load Balancer, para que
    #   toda instância criada já entre automaticamente recebendo tráfego.
    # - "--vpc-zone-identifier" define em quais subnets as instâncias
    #   vão subir (as duas privadas, uma em cada zona).
    # - "--health-check-type ELB" faz o Auto Scaling confiar no health
    #   check do Load Balancer (e não só no status básico da EC2) para
    #   decidir se uma instância está saudável.
    # - "--health-check-grace-period 120" dá 120 segundos de tolerância
    #   após o lançamento antes de considerar uma instância "unhealthy",
    #   tempo suficiente para o servidor web terminar de inicializar.

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
    # Cria a política de scaling do tipo "target tracking": em vez de eu
    # definir manualmente quando adicionar ou remover instâncias, digo
    # apenas qual métrica acompanhar (CPU média do grupo) e qual valor
    # alvo manter (50%). A AWS cuida de calcular sozinha quando escalar
    # para cima ou para baixo, com base nessa métrica.

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
    # Lista as instâncias atuais do Auto Scaling Group, mostrando o ID,
    # o estado do ciclo de vida (por exemplo, "InService") e o status
    # de saúde de cada uma. "--output table" formata o resultado como
    # uma tabela legível direto no terminal.

    log "Verificando saúde dos targets no Load Balancer..."

    aws elbv2 describe-target-health \
        --target-group-arn "$TARGET_GROUP_ARN" \
        --query 'TargetHealthDescriptions[*].[Target.Id,TargetHealth.State]' \
        --output table
    # Mostra, do ponto de vista do Load Balancer, se cada instância do
    # target group está "healthy" (recebendo tráfego normalmente) ou
    # "unhealthy" (fora de operação).
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
    # Chama as funções na ordem exata em que os recursos precisam existir:
    # primeiro a instância e a AMI, depois o Load Balancer (que já pode
    # existir independente do resto), depois o template e por último o
    # Auto Scaling Group, que depende de tudo que veio antes.

    log "Aguardando 60 segundos para as instâncias do ASG iniciarem..."
    sleep 60
    # Pausa fixa de 60 segundos para dar tempo das primeiras instâncias
    # do Auto Scaling Group começarem a subir antes de checar o status.
    # Não é um método muito preciso, mas é simples o suficiente para o
    # propósito do lab.

    check_status
    # Exibe o status final das instâncias e do Load Balancer.

    log "Deploy finalizado."
    log "Acesse a aplicação em: http://$ALB_DNS"
    log "Use o botão 'Start Stress' na página para testar o scale-out automático."
    # Mensagens finais com o link de acesso e a instrução de como testar
    # o comportamento do Auto Scaling na prática.
}

main
# Chama a função principal, que é o que efetivamente dispara toda a
# execução do script quando ele é rodado.
