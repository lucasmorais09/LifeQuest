# LifeQuest #

Aplicativo gamificado para organizar atividades diárias e criar hábitos. Desenvolvido como Trabalho de Graduação do curso de Tecnologia em Análise e Desenvolvimento de Sistemas da FATEC Sorocaba.

O usuário distribui suas metas em âmbitos da vida (Saúde, Estudos, Esportes etc.), agenda atividades com lembretes e conclui cada tarefa enviando uma selfie, que é validada por inteligência artificial. Atividades comprovadas geram pontos, moedas e troféus.

**Acesse o aplicativo:** [https://tglifequest.netlify.app/](https://tglifequest.netlify.app/)

## Conta de teste

Para conhecer o app sem criar uma conta, use o usuário de demonstração. Ele já vem com histórico de atividades, troféus, moedas, seguidores e publicações no feed.

| Campo | Valor |
| --- | --- |
| E-mail | `demo@lifequest.app` |
| Senha | `lifequest123` |
| Usuário | `@lifequester` |

Também é possível entrar pelo botão **Entrar com a conta de demonstração**, na tela de login.

> Os dados da conta de teste ficam salvos no navegador de quem acessa. Para voltar ao estado original, use **Configurações > Restaurar dados de exemplo**.

## Funcionalidades

- Cadastro, login e recuperação de senha
- Âmbitos com até duas prioridades (tarefas prioritárias valem 20 pontos; as demais, 10)
- Calendário com atividades, repetições, lembretes, notificações e cronômetro
- Conclusão de tarefas com selfie validada por IA
- Troféus de ofensiva, novo hábito e frequência
- Perfil, feed com reações (joia e coração), busca de usuários e seguidores
- Relatórios de insights comprados com moedas, válidos por 3 dias:

| Relatório | Custo |
| --- | --- |
| Retrospectiva semanal | 150 moedas |
| Raio-X da rotina | 200 moedas |
| Ranking entre amigos | 250 moedas |
| Retrospectiva mensal | 300 moedas |
| Mensal detalhado com IA | 500 moedas |

## Tecnologias

| Camada | Tecnologia |
| --- | --- |
| Aplicativo | HTML, CSS e JavaScript, hospedado no [GitHub Pages](https://pages.github.com/) |
| Autenticação, banco e arquivos | [Supabase](https://supabase.com/) (PostgreSQL com segurança em nível de linha) |
| Validação das fotos | [Cloudflare Workers](https://developers.cloudflare.com/workers/) + [Workers AI](https://developers.cloudflare.com/workers-ai/) (Llama 4 Scout) |

## Estrutura do repositório

```
index.html                         aplicativo (versão integrada ao Supabase)
worker/lifequest-worker.js         servidor de validação das selfies
database/01-lifequest-banco.sql    tabelas, regras de negócio e dados iniciais
database/02-migracao-supabase.sql  autenticação, permissões e políticas de segurança
docs/                              monografia e diagramas
```

## Como executar

1. **Banco de dados:** crie um projeto no Supabase e execute, no SQL Editor, os scripts da pasta `database/` na ordem numérica. Em Authentication, cadastre o endereço do app como Site URL e como URL de redirecionamento.
2. **Servidor:** crie um Worker no Cloudflare com o código de `worker/lifequest-worker.js`, adicione um binding do Workers AI chamado `AI` e configure as variáveis:
   - `SUPABASE_URL`: endereço do projeto no Supabase
   - `SUPABASE_SERVICE_ROLE_KEY`: chave secreta do Supabase (como **segredo**)
   - `ALLOWED_ORIGIN`: endereço do app no GitHub Pages
3. **Aplicativo:** em `index.html`, preencha `SUPABASE_URL`, `SUPABASE_KEY` (chave pública) e `WORKER_URL`, e publique o arquivo no GitHub Pages.

> Nunca coloque a chave secreta do Supabase no `index.html` nem no repositório: ela deve existir apenas nos segredos do Worker.

## Equipe

- [Lucas Oliveira de Morais]
- [Mellissa Wildemann Muniz]
- [Murilo Litoldo Carneiro]

Orientação: [Professor Deivison Shindi Takatu]
