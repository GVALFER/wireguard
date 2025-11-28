# Exemplo de Uso - WireGuard com Domínio Personalizado

Este documento demonstra como usar os scripts de WireGuard com domínio personalizado e links temporários para download de configurações.

## 🚀 Instalação com Domínio Personalizado

### Cenário 1: Usando Domínio Personalizado

```bash
sudo ./install-wireguard.sh
```

**Saída da instalação:**
```
🚀 WireGuard + Nginx Secure Links Installation
==============================================

Detecting public IP...
Detected public IP: 203.0.113.10

Do you want to use a custom domain for nginx? (y/N): y
Enter your domain (e.g., vpn.yourdomain.com): vpn.empresa.com

Found 2 NIC(s):
1) eth0 (UP, 203.0.113.10/24)
2) eth1 (UP, 192.168.1.1/24)

Auto-configuration:
NETWORK_1 (internet): eth0
NETWORK_2 (private): eth1

Configuration:
Interface: wg0
Port: 51820
VPN Network: 10.8.0.0/24
Private Network: 10.10.1.0/24
Public IP: 203.0.113.10
Server Domain/IP: vpn.empresa.com
Download Server: nginx on port 8080

Continue with auto-configuration? (Y/n): y
```

**Resultado:**
- Servidor WireGuard configurado
- Nginx configurado com `server_name vpn.empresa.com`
- Links de download usarão `http://vpn.empresa.com:8080/`

### Cenário 2: Usando IP (Modo Padrão)

```bash
sudo ./install-wireguard.sh
```

**Saída da instalação:**
```
🚀 WireGuard + Nginx Secure Links Installation
==============================================

Detecting public IP...
Detected public IP: 203.0.113.10

Do you want to use a custom domain for nginx? (y/N): n
Using IP address: 203.0.113.10

[... resto da configuração ...]

Server Domain/IP: 203.0.113.10
Download Server: nginx on port 8080
```

**Resultado:**
- Servidor WireGuard configurado
- Nginx configurado com IP público
- Links de download usarão `http://203.0.113.10:8080/`

## 📱 Criando Clientes

### Cliente com Domínio Personalizado

```bash
sudo ./create-client.sh laptop-joao
```

**Saída:**
```
🔐 Creating client: laptop-joao
================================
Assigned IP: 10.8.0.2
Link expires in: 2 hours

Server endpoint (default: vpn.empresa.com:51820):
> [Enter para aceitar ou digitar outro endpoint]

Client configuration:
Name: laptop-joao
IP: 10.8.0.2
Endpoint: vpn.empresa.com:51820
Expiry: 2 hours

Create client? (Y/n): y

✅ Client created!

🔗 Download Link:
==================
http://vpn.empresa.com:8080/laptop-joao.conf

📱 Temporary link for configuration download
⚠️  Files are automatically cleaned up after 24 hours
```

### Cliente com IP Específico

```bash
sudo ./create-client.sh celular-maria 10
```

**Explicação dos parâmetros:**
- `celular-maria`: nome do cliente
- `10`: IP suffix (10.8.0.10)

## 🔧 Gerenciamento

### Listar Clientes

```bash
sudo ./wg-manage.sh list
```

**Saída:**
```
🔌 WireGuard Clients:
====================
1. laptop-joao (10.8.0.2/32) ✅ 📥 🟢
2. celular-maria (10.8.0.10/32) ✅ 📥 🟡

Legend: ✅Config 📥Download 🟢Connected 🟡Configured ⚫Offline ❌Missing
```

### Gerar Novo Link de Download

```bash
sudo ./wg-manage.sh link laptop-joao
```

**Saída:**
```
🔗 Download Link for: laptop-joao
==================================
http://vpn.empresa.com:8080/laptop-joao.conf

📱 Temporary link for configuration download
⚠️  Files are automatically cleaned up after 24 hours

📋 Download commands:
curl -O 'http://vpn.empresa.com:8080/laptop-joao.conf'
wget 'http://vpn.empresa.com:8080/laptop-joao.conf'
```

### Status do Servidor

```bash
sudo ./wg-manage.sh status
```

**Saída:**
```
📊 Server Status:
=================

🟢 WireGuard: Running
🟢 Nginx: Running
🟢 Download Server: Operational (port 8080)

🌐 Server URLs:
Health: http://vpn.empresa.com:8080/health
Info: http://vpn.empresa.com:8080/

interface: wg0
  public key: ABC123...
  private key: (hidden)
  listening port: 51820

peer: XYZ789...
  preshared key: (hidden)
  endpoint: 198.51.100.5:54321
  allowed ips: 10.8.0.2/32
  latest handshake: 2 minutes, 15 seconds ago
```

## 🌐 Alterando o Domínio

### Usando o Script Automático (Recomendado)

```bash
sudo ./change-domain.sh
```

**Saída interativa:**
```
🌐 WireGuard Domain Configuration Updater
==========================================

Current domain/IP: vpn.empresa.com

Do you want to:
1) Use IP address (203.0.113.10)
2) Use custom domain
3) Cancel

Select option (1-3): 2
Enter your domain (e.g., vpn.yourdomain.com): new-vpn.empresa.com

Changing domain from 'vpn.empresa.com' to 'new-vpn.empresa.com'

Continue with domain change? (Y/n): y

Updating domain configuration...
Updating nginx configuration...
Nginx configuration test passed
Restarting nginx...
✅ Nginx restarted successfully

🎉 Domain change completed!

📋 Updated Configuration:
=========================
Previous: vpn.empresa.com
Current:  new-vpn.empresa.com
Public IP: 203.0.113.10

🌐 Updated URLs:
Health Check: http://new-vpn.empresa.com:8080/health
Info Page: http://new-vpn.empresa.com:8080/

✅ All services running successfully with new domain!
```

## 📝 Configuração de DNS

Para usar domínio personalizado, configure seu DNS:

### Registro A
```
vpn.empresa.com.    IN    A    203.0.113.10
```

### Registro CNAME (se usar subdomínio)
```
vpn.empresa.com.    IN    CNAME    servidor.empresa.com.
```

## 🔒 Exemplo de Configuração SSL (Opcional)

Para usar HTTPS com seu domínio:

### 1. Instalar Certbot
```bash
sudo apt install certbot python3-certbot-nginx
```

### 2. Obter Certificado
```bash
sudo certbot --nginx -d vpn.empresa.com
```

### 3. Atualizar Porta (opcional)
```bash
# Editar /etc/nginx/sites-available/wireguard-dl
# Mudar listen 8080; para listen 443 ssl;
sudo systemctl restart nginx
```

## 📊 Exemplo de URLs Geradas

### Com Domínio Personalizado
- Health Check: `http://vpn.empresa.com:8080/health`
- Download Link: `http://vpn.empresa.com:8080/cliente.conf`
- Info Page: `http://vpn.empresa.com:8080/`

### Com IP (modo padrão)
- Health Check: `http://203.0.113.10:8080/health`
- Download Link: `http://203.0.113.10:8080/cliente.conf`
- Info Page: `http://203.0.113.10:8080/`

## ✅ Verificação de Funcionamento

### 1. Testar Health Check
```bash
curl http://vpn.empresa.com:8080/health
# Resposta esperada: OK
```

### 2. Testar Info Page
```bash
curl http://vpn.empresa.com:8080/
# Resposta esperada: 🔐 WireGuard Secure Download Server...
```

### 3. Testar Link de Download
```bash
# Use um link real gerado pelo sistema
curl -I "http://vpn.empresa.com:8080/cliente.conf"
# Resposta esperada: HTTP/1.1 200 OK ou 404 se arquivo não existe
```

## 🎯 Casos de Uso

### Empresa com Domínio Próprio
```bash
# Instalação
sudo ./install-wireguard.sh
# Escolher domínio: vpn.minhaempresa.com

# Criar clientes para funcionários
sudo ./create-client.sh funcionario-joao
sudo ./create-client.sh gerente-maria 5  # IP específico
```

### Uso Pessoal com IP
```bash
# Instalação simples
sudo ./install-wireguard.sh
# Escolher IP (padrão)

# Criar dispositivos pessoais
sudo ./create-client.sh meu-laptop
sudo ./create-client.sh meu-celular
```

### Migração de IP para Domínio
```bash
# Após configurar DNS
sudo ./change-domain.sh
# Escolher opção 2 e inserir domínio
```

## 📋 Arquivos de Configuração

Após a instalação com domínio, você encontrará:

```
/etc/wireguard/
├── wg0.conf                    # Configuração principal do WireGuard
├── server_public_ip.txt        # IP público do servidor
├── server_domain.txt           # Domínio configurado (NOVO)
├── server_secret_key.txt       # Chave secreta para links
├── server_private.key          # Chave privada do servidor
├── server_public.key           # Chave pública do servidor
└── clients/                    # Configurações dos clientes
    ├── laptop-joao.conf
    └── celular-maria.conf

/var/www/wireguard-dl/          # Arquivos para download
├── laptop-joao.conf
└── celular-maria.conf
```

## 🎉 Vantagens do Domínio Personalizado

1. **Profissional**: URLs mais amigáveis
2. **Memorável**: Mais fácil de lembrar que IPs
3. **Flexível**: Pode mudar IP sem afetar clientes
4. **SSL-Ready**: Pronto para certificados HTTPS
5. **Branding**: Usa seu domínio da empresa
6. **Simplicidade**: Links diretos e limpeza automática após 24h