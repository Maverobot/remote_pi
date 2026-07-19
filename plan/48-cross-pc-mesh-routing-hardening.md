# Plano 48 — Roteamento mesh cross-PC canônico

**Status:** implementação entregue em `36206d8`; limpeza e validação final em andamento
**Baseline:** `181625b`
**Subprojetos:** `pi-extension/` e `relay/`

## Contexto

O roteamento cross-PC usava nickname/prefixo como se fosse identidade técnica.
Isso tornava a visão assimétrica entre máquinas: cada receptor podia conhecer um
nickname diferente para a mesma Pi-key, causando destinos não roteáveis, spoofing
de apresentação e timeouts sem diagnóstico confiável.

A correção separa duas coisas:

- **identidade técnica:** chave pública Ed25519 canônica de 32 bytes;
- **apresentação:** alias local calculado pelo receptor.

O Relay continua mediando o tráfego; não há P2P direto nem E2E. TLS protege o
trânsito, mas o operador do Relay pode observar o conteúdo atual.

## Escopo

- Canonicalizar identidade Pi/PC no Relay e na Extension.
- Autorizar somente co-membership direta em um Owner válido.
- Gerar aliases locais determinísticos e não ambíguos.
- Preservar endereços locais exatos antes de tentar roteamento remoto.
- Entregar erros confiáveis do Relay sem alterar os status públicos.
- Tornar leitura de topologia, SelfRevoke e deadlines fail-closed.
- Manter compatibilidade de rollout com Extension primeiro.

## Fora de escopo

- Alterações no app Android/iOS, Cockpit ou Site.
- Mudança de pareamento, short IDs, room IDs ou formato de `peers.json`.
- Migração ou mudança de schema do SQLite do Relay.
- Coordenação SelfRevoke persistente entre processos.
- E2E encryption ou transporte P2P.
- Publicação de imagem/pacote ou deployment automático.

## Estrutura esperada

### Relay

- Um decoder compartilhado aceita somente chave Ed25519 de 32 bytes e produz
  Base64 RFC 4648 padrão com padding.
- O `pi_forward` usa a chave autenticada da conexão como `from_pc` e uma chave
  canônica como `to_pc`.
- Autorização exige um único blob Owner válido contendo diretamente origem e
  destino.
- Um membro malformado invalida a contribuição inteira daquele Owner.
- Grants positivos expiram em até 60 segundos; miss de destino força refresh.
- Resultados negativos não são cacheados.
- Erros reservados usam apenas `offline`, `not_authorized` ou `bad_envelope`.

### Extension

- Pi-key e Owner-key são normalizadas somente depois das verificações
  criptográficas necessárias.
- A topologia contém apenas irmãos de Owners válidos que incluem a Pi local.
- Aliases são calculados localmente pelo receptor e nunca usados como prova de
  identidade ou autorização.
- O broker resolve primeiro um endereço local exatamente registrado; isso inclui
  caminhos Windows com `:` de drive.
- Frames recebidos usam `from_pc` autenticado e renderizam `envelope.from` com o
  alias local do receptor.
- Apenas erros `_relay` com outer e grammar exatos liquidam operações pendentes.
- Erros forjados continuam conteúdo comum e não ganham autoridade.
- Leituras de topologia têm deadline finito e distinguem ausência autoritativa,
  dado inválido e indisponibilidade.
- SelfRevoke remove o registro bruto correto e desanexa o canal canônico ativo.

## Contrato final

### Identidade canônica

A identidade é Base64 padrão com padding dos 32 bytes crus da chave Ed25519.
Entradas URL-safe ou sem padding podem ser aceitas para normalização, mas toda
comparação e saída técnica usa a forma canônica.

Nicknames, aliases e prefixes nunca substituem a chave técnica.

### Aliases locais

- Bytes UTF-8 fora de `[A-Za-z0-9._-]` são codificados como `%HH` maiúsculo.
- `~<prefixo-base64url-da-chave>` resolve colisões.
- O prefixo cresce de forma adaptativa até ficar único.
- Ausência de nickname usa `pc-<prefixo-da-chave>`.
- Cada receptor pode renderizar aliases diferentes para a mesma chave.

### Autorização

`authorized(A, B)` é verdadeiro somente quando existe um Owner válido cujo blob
contém A e B diretamente. Blobs `{A,B}` e `{B,C}` não autorizam `A → C`.
Uma contribuição Owner com qualquer membro inválido não concede autorização.

### Cache

- TTL positivo máximo: 60 segundos.
- Omissão do destino força uma leitura autoritativa antes da resposta final.
- Falhas, negativos e storage indisponível não viram grant cacheado.

### Endereçamento

O endereço público é `[<alias-local>:]<cwd>@<agent>`. Chamadores devem copiar o
valor completo de `list_peers` sem parsear, reconstruir, decodificar ou alterar
case. Um endereço local exatamente registrado sempre vence antes do alias remoto.

### Erros e ACK

Status públicos permanecem:

- `received` para entrega aceita;
- `denied` para `not_authorized` ou `bad_envelope` confiável;
- `timeout` para `offline` confiável ou silêncio real;
- `sent` para broadcast sem ACK.

Apenas um outer autenticado de `_relay`, com envelope reservado válido, reason
fechado e UUID correlacionável, pode liquidar pending state. Settlement ocorre no
máximo uma vez.

### Topologia e SelfRevoke

- Leitura estrita bem-sucedida é a única evidência autoritativa.
- Storage indisponível nunca significa conjunto vazio.
- Ausência autoritativa remove confiança; dados inválidos são isolados.
- Reconciliação de Owners ativos desanexa canais privados revogados.
- Uma re-pair concorrente válida não pode ser apagada por remoção obsoleta.

## Passos e critérios de aceite

### 1. Relay canônico

- Validar hello, membership e forwarding na mesma fronteira de 32 bytes.
- Cobrir Base64 padrão/URL-safe, padding, comprimento e caracteres inválidos.
- Provar autorização direta, não transitiva e independente da ordem dos Owners.
- Provar invalidade completa da contribuição com membro malformado.
- Provar TTL, refresh em miss e grammar exata de erros.

**Aceite:** testes unitários e integração do Relay passam; fmt, clippy e release
build passam; nenhum payload, chave ou assinatura é logado.

### 2. Extension canônica

- Implementar aliases determinísticos e bijetivos por chave.
- Preservar precedência local exata e drive letters Windows.
- Normalizar inbound pelo `from_pc` autenticado.
- Implementar deadline finito e classificação estrita de leitura.
- Preservar status públicos e settlement confiável de erros.

**Aceite:** testes de encoding, topology, broker remoto, envelope, tools, MCP e
round trip passam sem alterar pareamento, room ID ou storage schema.

### 3. Revogação e reconciliação

- Remover o registro bruto correspondente sem normalizar o arquivo inteiro.
- Desanexar o canal pela identidade canônica.
- Reconciliar Owners ativos somente após snapshot estrito autoritativo.
- Preservar estado em outage/invalidade não autoritativa.

**Aceite:** ausência, malformed isolation, outage retention e re-pair race têm
regressões públicas/duráveis.

### 4. Compatibilidade e rollout

- Atualizar todas as Extensions capazes de liderar antes do Relay.
- Preservar configuração, volume, bind e restart policy do Relay.
- Manter rollback de pacote/container e backup do volume fora do repositório.
- Validar Mac → RTX e RTX → Mac com endereço retornado por `list_peers`.

**Aceite:** ambos os hosts carregam o mesmo runtime aprovado; Relay fica healthy;
round trip físico recebe ACK e reply correlacionada sem re-pairing.

### 5. Limpeza de escopo

- Remover contratos e planos duplicados.
- Restaurar short IDs públicos de pareamento ao prefixo EPK existente.
- Manter somente testes de comportamento público, regressões reais e contratos
  de segurança; remover matrizes de estado privado, wording e callback order.
- Centralizar detalhes técnicos em `PROTOCOL.md` e manter READMEs concisos.

**Aceite:** diff final não contém mudança mobile/schema/pairing, testes
exploratórios ou documentação operacional duplicada.

## Definition of Done

- [x] Identidade técnica canônica implementada nos dois lados.
- [x] Aliases receiver-local e precedência local exata implementados.
- [x] Autorização direta, invalidade Owner inteira e cache limitado implementados.
- [x] Erros confiáveis preservam status públicos e settlement único.
- [x] Topologia estrita, SelfRevoke e reconciliação ativa implementados.
- [x] Extension `0.5.6` validada nos dois PCs.
- [x] Relay `0.2.4` validado e healthy com configuração preservada.
- [x] Mac → RTX e RTX → Mac verificados fisicamente.
- [x] Short IDs públicos restaurados e diff/testes/documentação enxugados.
- [x] Validação final de Extension e Relay verde após a limpeza.
- [x] Revisão final sem blocker/high/medium.

## Próximos passos

Nenhum por padrão. Publicação, PR upstream, cleanup de rollback e hardening do
verificador de artefatos continuam ações separadas e explicitamente aprovadas.
