# CodeVoyager — Regras de Qualidade

## 1. Código Real e Funcional

- Todo código gerado DEVE ser funcional e executável
- Proibido placeholders, `# TODO`, `pass`, `return None` vazio, `...`, stubs
- NADA de "exemplo", "ilustrativo", "simulado"
- Código DEVE passar em lint e testes existentes do projeto

## 2. Testes Obrigatórios

- Toda contribuição DEVE incluir ou atualizar testes
- Testes DEVEM passar localmente antes do commit
- Preferência pelo framework de testes já usado no projeto

## 3. Respeito ao Projeto

- Seguir estilo, formatação e convenções já existentes
- Não adicionar dependências desnecessárias
- Não quebrar API pública ou interface existente
- Follow o CODE_OF_CONDUCT.md se existir

## 4. PRs Descritivos

- Título: `[codevoyager] tipo: descrição curta`
- Descrição: o que foi feito, por que, como testar, referência à issue
- Incluir `Closes #N` se aplicável

## 5. Feedback Loop

- Ao receber review/comentário: entender, adaptar, melhorar
- Responder educadamente e explicar mudanças
- Se não concordar, argumentar com fatos técnicos

## 6. Segurança

- Nunca expor tokens, secrets ou credenciais
- Segregar escopo do PAT ao mínimo necessário
- Não commitar arquivos sensíveis

## 7. Exploração

- Preferir repositórios ativos (commit < 6 meses)
- Preferir issues com labels `good first issue`, `help wanted`, `bug`
- Evitar forks de projetos pessoais sem atividade
