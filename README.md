# Auto Scaling na AWS com Linux
<img width="1704" height="1038" alt="image" src="https://github.com/user-attachments/assets/32675740-69a1-45e8-8945-c1668a7cfc1b" />

## Sobre este lab

Esse laboratório fez parte do módulo de Escala e Resolução de Nomes do curso AWS re/Start. O objetivo era colocar em prática o Auto Scaling usando instâncias Linux, entendendo como a AWS consegue aumentar ou reduzir a quantidade de servidores automaticamente de acordo com a demanda.

Usei a AWS CLI para criar uma instância EC2, transformei essa instância em uma imagem (AMI) e depois usei essa imagem como base para configurar um grupo de Auto Scaling. No final, também configurei um Load Balancer para distribuir o tráfego entre as instâncias criadas em diferentes zonas de disponibilidade.

## O que eu já sabia e o que era novo

Eu já tinha alguma noção do que é uma instância EC2, mas ainda não tinha usado a AWS CLI para criar recursos — até então tinha feito tudo pelo console. Então esse lab também serviu para eu me acostumar com comandos do CLI, tipo `aws ec2 run-instances` e `aws ec2 create-image`.

A parte de Auto Scaling em si era completamente nova pra mim. Entender a diferença entre capacidade desejada, mínima e máxima, e como isso se conecta com uma política de scaling baseada em CPU, foi o que exigiu mais atenção.

## O que eu fiz na prática

### 1. Criando uma instância via AWS CLI

Comecei conectando na instância "Command Host" que já vinha provisionada no ambiente do lab, usada só para rodar os comandos da CLI. De lá, configurei o `aws configure` com a região correta e criei uma nova instância EC2 rodando um comando parecido com esse:

```bash
aws ec2 run-instances \
  --key-name KEYNAME \
  --instance-type t3.micro \
  --image-id AMIID \
  --user-data file:///home/ec2-user/UserData.txt \
  --security-group-ids HTTPACCESS \
  --subnet-id SUBNETID \
  --associate-public-ip-address \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=WebServer}]'
```

Essa instância já subia com um script de user data que instalava uma aplicação PHP simples, usada mais tarde para simular carga alta de CPU.

Depois de confirmar que o servidor web estava respondendo (acessando o DNS público da instância no navegador), usei esse mesmo servidor como base para criar uma AMI:

```bash
aws ec2 create-image --name WebServerAMI --instance-id NEW-INSTANCE-ID
```

Essa AMI passou a ser o "molde" usado para criar novas instâncias idênticas dentro do Auto Scaling Group.

### 2. Configurando o Load Balancer

Antes de mexer no Auto Scaling, criei um Application Load Balancer (`WebServerELB`), configurado para operar nas duas subnets públicas do VPC do lab. Criei também um target group (`webserver-app`) apontando para o caminho `/index.php` como health check.

Essa etapa deixou claro pra mim por que o Load Balancer entra antes do Auto Scaling: ele é quem vai distribuir as requisições entre as instâncias que o Auto Scaling for criando, então precisa existir primeiro.

### 3. Criando o Launch Template

Com a AMI pronta, criei um launch template (`web-app-launch-template`) definindo o tipo de instância (`t3.micro`), a AMI usada e o security group de acesso HTTP. O launch template funciona como uma receita: define tudo que uma nova instância precisa ter quando for lançada pelo Auto Scaling.

### 4. Criando o Auto Scaling Group

A partir do launch template, criei o Auto Scaling Group (`Web App Auto Scaling Group`) com:

- Capacidade desejada: 2 instâncias
- Capacidade mínima: 2
- Capacidade máxima: 4
- Subnets privadas, distribuídas entre duas zonas de disponibilidade
- Política de scaling por rastreamento de destino (target tracking), usando CPU média em 50% como referência

Foi nesse ponto que entendi melhor o papel do "target tracking": em vez de eu definir manualmente quando escalar, a AWS monitora a métrica de CPU continuamente e ajusta o número de instâncias para tentar manter esse valor perto do alvo definido.

### 5. Testando o Auto Scaling

Para verificar se tudo estava funcionando, acessei a aplicação pelo DNS do Load Balancer e usei o botão "Start Stress", que força a CPU da instância a subir até 100%. Depois de alguns minutos acompanhando a aba Activity do Auto Scaling Group, vi uma nova instância sendo criada — o CloudWatch detectou que a CPU média ultrapassou os 50% configurados e a política de scale-out entrou em ação.

## O que eu entendi com esse lab

O principal aprendizado foi visualizar, na prática, como as peças se conectam: AMI, launch template, Auto Scaling Group e Load Balancer trabalham juntos para manter a aplicação disponível mesmo com variação de carga, sem precisar de intervenção manual.

Também ficou mais claro pra mim o motivo de usar subnets privadas para as instâncias do Auto Scaling Group, deixando só o Load Balancer exposto nas subnets públicas — é uma prática de segurança que reduz a superfície de ataque da aplicação.

## Possíveis próximos passos

Isso aqui não foi feito no lab, mas são pontos que pretendo estudar mais pra frente:

- Automatizar essa criação inteira com CloudFormation, em vez de configurar manualmente pelo console.
- Testar políticas de scaling baseadas em outras métricas, além de CPU (como número de requisições por instância).
- Entender melhor como configurar alarmes de scale-in para reduzir custo quando a demanda cai.

## Ferramentas utilizadas

- AWS CLI
- Amazon EC2
- Amazon Machine Image (AMI)
- Amazon EC2 Auto Scaling
- Elastic Load Balancing (Application Load Balancer)
- Amazon CloudWatch (para o monitoramento de CPU que aciona o scaling)
