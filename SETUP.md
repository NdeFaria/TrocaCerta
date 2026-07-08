# Troca Certa — guia de publicação

Isso te leva do zero até o app no ar, com login real, banco de dados real e
notificação push. São ~25-40 minutos de configuração, não é código — é clicar
em botões e colar chaves. Siga na ordem.

## 1. Criar o projeto no Supabase (5 min)

1. Vá em https://supabase.com → **New project**.
2. Anote a **senha do banco** que você definir (não precisa mais depois, mas guarde).
3. Espere o projeto provisionar (~2 min).
4. Menu lateral → **SQL Editor** → **New query**.
5. Abra o arquivo `supabase/schema.sql` deste pacote, copie tudo e cole lá.
6. Clique **Run**. Deve aparecer "Success. No rows returned".
   - Isso cria as tabelas, as políticas de segurança (RLS) e as funções
     (`create_car`, `register_oil_change`, `get_public_car`, `claim_transfer`, etc).

## 2. Pegar as chaves da API (2 min)

1. Menu lateral → **Project Settings** → **API**.
2. Copie **Project URL** e a chave **anon public**.
3. Abra `index.html`, procure por:
   ```js
   const SUPABASE_URL = 'https://SEU-PROJETO.supabase.co';
   const SUPABASE_ANON_KEY = 'SUA-ANON-KEY-AQUI';
   ```
4. Cole os valores reais ali.

⚠️ A chave `anon` é pública por design (fica exposta no navegador de qualquer
jeito) — a segurança de verdade está nas políticas RLS e nas funções que você
rodou no passo 1. **Nunca** coloque a chave `service_role` no `index.html`.

## 3. Configurar autenticação por e-mail (3 min)

1. **Authentication** → **Providers** → confirme que **Email** está ativado.
2. **Authentication** → **URL Configuration**:
   - **Site URL**: coloque a URL final do site (ex: `https://trocacerta.netlify.app`)
     — você pode voltar aqui depois de publicar no passo 6 e atualizar.
3. Se quiser pular a confirmação por e-mail no começo (pra testar mais rápido):
   **Authentication** → **Providers** → **Email** → desative "Confirm email".
   Reative antes de comercializar de verdade.

## 4. Notificação push (opcional nesta etapa, pode fazer depois)

Web Push exige um par de chaves VAPID e uma função que roda no servidor
(o navegador sozinho não consegue "avisar" o usuário quando o app está fechado).

1. Gere as chaves (no seu computador, com Node instalado):
   ```
   npx web-push generate-vapid-keys
   ```
   Isso imprime uma **Public Key** e uma **Private Key**.
2. No `index.html`, cole a Public Key em:
   ```js
   const VAPID_PUBLIC_KEY = 'SUA-VAPID-PUBLIC-KEY-AQUI';
   ```
3. Instale a Supabase CLI (`npm install -g supabase`) e rode, na pasta deste projeto:
   ```
   supabase login
   supabase link --project-ref SEU-PROJECT-REF
   supabase secrets set VAPID_PUBLIC_KEY=... VAPID_PRIVATE_KEY=... VAPID_SUBJECT=mailto:voce@seudominio.com
   supabase functions deploy notificar-trocas
   supabase functions schedule notificar-trocas --cron "0 12 * * *"
   ```
   Isso faz a função rodar 1x por dia, checar quais carros estão perto/atrasados
   e mandar a notificação push pra quem tiver o app instalado com permissão concedida.

**Limitação real que você precisa saber:** no iPhone, notificação push de PWA só
funciona se o usuário **instalar o app na tela de início** (Compartilhar →
Adicionar à Tela de Início) e estiver em iOS 16.4 ou mais recente. Direto pelo
Safari, sem instalar, não funciona. No Android/Chrome funciona mesmo sem instalar,
mas instalado é mais confiável. Vale deixar isso claro pro usuário dentro do app.

## 5. Testar localmente antes de publicar

Abra o `index.html` direto no navegador (ou rode `python3 -m http.server` na
pasta e acesse `http://localhost:8000`) e teste o fluxo inteiro:
criar conta → cadastrar carro → ver QR → baixar QR → registrar troca →
gerar código de transferência → abrir o link público do QR numa aba anônima
(deve mostrar histórico sem placa/RENAVAM) → assumir o carro com outra conta.

## 6. Publicar no Netlify (5 min)

1. https://app.netlify.com → **Add new site** → **Deploy manually**.
2. Arraste a pasta inteira `troca-certa/` (com `index.html`, `manifest.json`,
   `sw.js`, `icons/`) pra área de upload.
3. Netlify te dá uma URL tipo `https://algum-nome.netlify.app`.
4. Volte no Supabase (passo 3) e atualize a **Site URL** com essa URL.
5. (Opcional) **Domain settings** → **Add custom domain** pra usar seu próprio
   domínio (ex: `trocacerta.com.br`) — o Netlify te dá os registros DNS pra
   configurar no seu provedor de domínio.

Depois disso o site está público, funcional, com login real e dados reais.

## 7. Sobre "instalar como app" (PWA)

Não precisa de loja de app. No celular, ao abrir o site:
- **Android/Chrome**: aparece um banner "Adicionar à tela inicial" automaticamente,
  ou menu ⋮ → "Instalar app".
- **iPhone/Safari**: botão Compartilhar → "Adicionar à Tela de Início".

## 8. Próximo passo (não incluído neste pacote): cobrança com Stripe

Você mencionou planos pagos (R$5–15/mês). Isso é uma etapa separada porque
envolve: criar produtos no Stripe, uma Edge Function pra criar sessões de
checkout, webhook pra liberar/bloquear funcionalidades por assinatura, e uma
coluna `plan_status` na tabela de usuários. Prefiro fazer isso como um segundo
pacote, depois que você validar que o fluxo de cadastro/QR/transferência está
100% redondo com usuários reais — me chama quando quiser essa parte.

## Resumo do que ficou protegido

- Placa e RENAVAM ficam em `car_documents`, tabela com RLS que só libera leitura
  pro dono (`owner_id = auth.uid()`). Nunca são retornados pela função pública.
- Quem escaneia o QR chama `get_public_car(token)`, uma função que devolve
  **só** apelido, KM, status e histórico — sem nomes, sem documentos.
- Cadastrar um carro exige RENAVAM (`create_car`), como prova de posse dos documentos.
- Transferir posse exige código de uso único **+** RENAVAM batendo com o
  cadastrado (`claim_transfer`) — não dá pra "roubar" um carro só fotografando
  o QR colado no vidro.
