# WireGuard com Links Temporários Simplificados

## 🎯 Objetivo

Simplificar o sistema de download de configurações WireGuard, removendo a dependência do módulo `secure_link` do nginx e criando uma solução mais robusta e fácil de implementar.

## ❌ Problema Original

```bash
[WARN] Nginx secure_link module not found. Links may not work properly.
[WARN] Consider recompiling nginx with --with-http_secure_link_module
nginx: [emerg] unknown directive "secure_link" in /etc/nginx/sites-enabled/wireguard-dl:24
```

**Problemas identificados:**
- Dependência de módulo nginx não disponível em instalações padrão
- Complexidade desnecessária para o objetivo simples de compartilhar configurações
- Falha na instalação em sistemas Ubuntu/Debian padrão

## ✅ Solução Simplificada

### Abordagem Atual
- **Links diretos** para arquivos de configuração
- **Limpeza automática** após 24 horas
- **Domínio personalizado** mantido
- **Configuração nginx simples** sem módulos especiais

### Como Funciona

1. **Cliente criado** → Arquivo `.conf` copiado para `/var/www/wireguard-dl/`
2. **Link gerado** → `http://dominio:8080/cliente.conf`
3. **Download direto** → Nginx serve o arquivo diretamente
4. **Limpeza automática** → Cron remove arquivos > 24h

## 🔧 Modificações Realizadas

### `install-wireguard.sh`
- ❌ Removido: Verificação do módulo `secure_link`
- ❌ Removido: Configuração complexa do nginx com `secure_link_md5`
- ❌ Removido: Geração de chave secreta
- ✅ Adicionado: Configuração nginx simples para servir arquivos
- ✅ Mantido: Opção de domínio personalizado
- ✅ Mantido: Limpeza automática via cron

### `create-client.sh`
- ❌ Removido: Geração de links com hash e expiração
- ❌ Removido: Parâmetro de horas de expiração
- ✅ Simplificado: Links diretos `http://dominio/cliente.conf`
- ✅ Mantido: Cópia de arquivo para diretório de download

### `wg-manage.sh`
- ❌ Removido: Lógica complexa de geração de links seguros
- ❌ Removido: Parâmetro de horas nos comandos
- ✅ Simplificado: Comando `link` gera URL direta
- ✅ Mantido: Todas as outras funcionalidades

### `change-domain.sh`
- ✅ Mantido: Funcionalidade completa de mudança de domínio
- ✅ Simplificado: Sem referências a chaves secretas

## 📂 Estrutura de Arquivos

### Antes (Complexo)
```
/etc/wireguard/
├── server_secret_key.txt      # Chave para secure_link
├── server_secure_link.txt     # Flag do módulo
└── ...
```

### Agora (Simples)
```
/etc/wireguard/
├── server_domain.txt          # Domínio configurado
├── wg0.conf                   # Configuração WireGuard
└── clients/                   # Configurações dos clientes
```

## 🌐 Configuração Nginx

### Antes (Com secure_link)
```nginx
location ~ ^/wg-dl/([0-9]+)/([a-f0-9]+)/(.+)$ {
    secure_link $2 $1;
    secure_link_md5 "$secure_link_expires$uri $SECRET_KEY";
    # ... lógica complexa
}
```

### Agora (Simples)
```nginx
location ~* \.conf$ {
    add_header Content-Disposition "attachment";
    try_files $uri =404;
}
```

## 💡 Exemplo de Uso

### Instalação
```bash
sudo ./install-wireguard.sh

# Escolher domínio personalizado
Do you want to use a custom domain for nginx? (y/N): y
Enter your domain: vpn.empresa.com
```

### Criação de Cliente
```bash
sudo ./create-client.sh laptop-joao

# Resultado:
🔗 Download Link:
==================
http://vpn.empresa.com:8080/laptop-joao.conf

📱 Temporary link for configuration download
⚠️  Files are automatically cleaned up after 24 hours
```

### Download do Cliente
```bash
# Cliente baixa diretamente
curl -O http://vpn.empresa.com:8080/laptop-joao.conf

# Ou via browser
# http://vpn.empresa.com:8080/laptop-joao.conf
```

## 🔒 Segurança

### Medidas de Segurança Mantidas
- ✅ **Headers de segurança** (X-Frame-Options, X-Content-Type-Options)
- ✅ **Disable directory browsing**
- ✅ **Block sensitive files** (dotfiles)
- ✅ **Auto-cleanup** remove arquivos antigos
- ✅ **Permissions apropriadas** (644 para configs)

### Considerações
- Links são **públicos** por URL (security through obscurity)
- **Não há autenticação** no nginx (opcional via basic auth)
- **Cleanup automático** após 24h limita exposição
- **Arquivos temporários** não persistem indefinidamente

## 🎉 Vantagens da Solução

### ✅ Simplicidade
- Funciona em **qualquer nginx** padrão
- **Sem dependências** de módulos especiais
- **Instalação sempre funciona**

### ✅ Manutenibilidade
- **Configuração clara** e legível
- **Menos código** para manter
- **Debugs mais fáceis**

### ✅ Funcionalidade
- **Domínio personalizado** mantido
- **Cleanup automático** funcional
- **URLs profissionais** com domínio próprio

### ✅ Compatibilidade
- **Ubuntu/Debian** padrão ✅
- **CentOS/RHEL** ✅
- **Docker** containers ✅
- **Qualquer nginx** ✅

## 🔄 Migração

### Se Já Instalado (Versão Antiga)
```bash
# 1. Fazer backup
sudo ./wg-manage.sh backup

# 2. Reinstalar nginx config
sudo ./change-domain.sh

# 3. Testar funcionamento
curl http://seu-dominio:8080/health
```

### Instalação Nova
```bash
# Funciona imediatamente
sudo ./install-wireguard.sh
```

## 📊 Comparação

| Aspecto | Versão Anterior | Versão Simplificada |
|---------|----------------|-------------------|
| **Dependências** | nginx + secure_link | nginx padrão |
| **Compatibilidade** | Limitada | Universal |
| **Complexidade** | Alta | Baixa |
| **Manutenção** | Difícil | Fácil |
| **Segurança** | Hash + expiração | Cleanup automático |
| **URLs** | `/wg-dl/123/abc/file.conf` | `/file.conf` |
| **Debugging** | Complexo | Simples |

## 🎯 Conclusão

A **abordagem simplificada** mantém toda a funcionalidade essencial (domínio personalizado, cleanup automático, URLs profissionais) enquanto remove a complexidade e problemas de compatibilidade do módulo `secure_link`.

**Resultado:** Sistema mais robusto, fácil de instalar e manter, funcionando em qualquer ambiente nginx padrão.