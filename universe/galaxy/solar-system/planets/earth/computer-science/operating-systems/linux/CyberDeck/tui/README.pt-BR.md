# tui

Explorador de pacotes para o **gerenciador de pacotes CyberDeck** — uma
interface de terminal (Rust + ratatui): pesquise **todos** os pacotes
conhecidos, inspecione o pin e a procedência de cada um, percorra o que
ele exige e o que o exige, com busca difusa rápida e interface
priorizando o teclado.

```
┌─ Search: emac▌────────────────────────────────────────────────┐
│  [Overview(1)] [Dependencies(2)] [Reverse deps(3)]            │
│ ┌───────────────────────────┐ ┌──────────────────────────────┐│
│ │ ▶ emacs  30.2  GPL 3+     │ │ GNU Emacs is an extensible…   ││
│ │   emacs-minimal  30.2     │ │                              ││
│ │   emacs-next  31.0        │ │ Source: example.org/emacs.git ││
│ │   (fuzzy match highlights)│ │ Commit: 9edb3f66              ││
│ └───────────────────────────┘ └──────────────────────────────┘│
│ 157 matches · 10 pkgs · cache fresh · 9edb3f6 · ? help        │
└───────────────────────────────────────────────────────────────┘
```

## Recursos

- **Pesquise tudo** — busca difusa em todos os pacotes (nome + sinopse),
  com destaque dos trechos coincidentes e resultados ao vivo.
- **Detalhes do pacote** — versão, descrição, licenças, página inicial,
  além da procedência do gerenciador: URL do fonte, commit fixado,
  estado de instalação.
- **Dependências** — árvore expansível (`P` propagada, `N` nativa),
  com contagem de dependentes por nó (`⤴ 12`).
- **Dependentes** — "quem depende deste pacote": lista direta mais
  seção transitiva com limite de profundidade.
- **Inicialização instantânea** — o último instantâneo válido fica em
  cache como JSON gzipado; `--rebuild` relê o arquivo.
- **Sem varredura** — o TUI nunca executa subprocessos. O gerenciador
  escreve o instantâneo; o TUI só o lê.

## Arquivo de instantâneo (a junção com o CLI)

O TUI lê um único documento JSON — o instantâneo de pacotes. Ordem de
resolução:

1. `tui --snapshot PATH`
2. `$CYBERDECK_SNAPSHOT`
3. `./snapshot.json`

Esquema (`schema: 3`):

```json
{
  "header": {
    "schema": 3,
    "state": "9edb3f66",
    "generated_ms": "0",
    "package_count": 2
  },
  "packages": [
    {
      "id": 0,
      "name": "emacs",
      "version": "30.2",
      "synopsis": "The extensible text editor",
      "description": "GNU Emacs is an extensible text editor.",
      "homepage": "https://www.gnu.org/software/emacs/",
      "licenses": ["GPL 3+"],
      "inputs": ["gtk+"],
      "propagated_inputs": [],
      "native_inputs": ["texinfo"],
      "deps": ["gtk+", "texinfo"],
      "source_url": "https://example.org/emacs.git",
      "commit": "9edb3f66",
      "status": "installed"
    }
  ]
}
```

Regras:

- `id` vai de `0` a `package_count - 1`, sem repetir, e
  `package_count` deve ser igual ao tamanho de `packages`.
- `deps` lista os pins exatos e vence as três listas legadas
  (`inputs*`) quando ambas existem; nomes desconhecidos são
  descartados, nunca fatais.
- `file` (`[path, line]`) é metadado legado e opcional; os demais
  campos assumem vazio quando ausentes, então documentos antigos
  continuam válidos.

O futuro comando `pm` emitirá exatamente este documento; até lá,
qualquer ferramenta que escreva o formato acima funciona.

## Interface web

`tui web` serve o mesmo explorador como site local em
<http://127.0.0.1:8787>: caixa de busca difusa no topo e painel de
detalhes com chips clicáveis. Links profundos (`#/p/emacs`) podem ser
compartilhados e funcionam com o botão voltar; o leiaute é responsivo
até telas de telefone. O servidor escuta só em 127.0.0.1 e rejeita
cabeçalhos Host não locais.

API (JSON só leitura, toda resposta traz `generation`):

- `GET /api/v1/health` — `{ ok, packages, generation, state, phase }`
- `GET /api/v1/search?q=…&limit=…` — resultados ordenados com destaques
- `GET /api/v1/package/{name}` — detalhes com `deps`, `dependents`,
  `source_url`, `commit`, `status`

## Temas

As duas interfaces trazem oito temas: **dark** (padrão), **one**,
**light**, **dracula**, **nord**, **gruvbox-dark**, **tokyo-night** e
**catppuccin-mocha**.

- TUI: `T` alterna (o tema ativo aparece na barra de estado);
  `NO_COLOR` é respeitado com paleta em tons de cinza.
- Web: escolha no seletor da barra superior; a escolha é lembrada
  entre sessões.

## Requisitos

- Rust 1.85+ (edição 2021) para compilar do fonte.
- Um arquivo de instantâneo JSON (ver acima) para explorar.

## Instalação

```sh
git clone <seu-remote-cyberdeck> cyberdeck
cd cyberdeck/tui
cargo install --path .            # instala em ~/.cargo/bin
tui --snapshot /caminho/para/snapshot.json
```

## Uso

```
tui --snapshot snapshot.json       inicia o explorador
tui --rebuild --snapshot snap.json relê o instantâneo, atualiza o cache
tui web --snapshot snap.json      serve a web UI em 127.0.0.1:8787
tui --help                         todas as opções
```

`CYBERDECK_SNAPSHOT` define o caminho padrão para omitir a flag.

### Teclas

| Tecla | Ação |
|---|---|
| digitar | busca difusa (sempre ao vivo) |
| `Esc` | limpa a busca / volta |
| `Tab` / `Shift+Tab` | alterna abas |
| `1`–`3` | pula para a aba (Overview, Dependencies, Reverse deps) |
| `↑` `↓` (ou `j` `k` com busca vazia) | move a seleção |
| `PgUp` / `PgDn` | página |
| `Enter` | expande/recolhe o nó da árvore |
| `d` / `r` (busca vazia) | abre dependências / dependentes |
| `h` / `l` ou `←` / `→` | recolhe / expande o nó |
| `g` / `G` (busca vazia) | topo / fim |
| `o` (busca vazia) | abre a página em `$BROWSER`/`xdg-open` |
| `T` | alterna tema (8 paletas) |
| `R` | recarrega o instantâneo em segundo plano |
| `?` | ajuda |
| `q` (busca vazia) / `Ctrl+C` | sai |

### Abas

1. **Overview** — lista de resultados + painel de detalhes.
2. **Dependencies** — árvore expansível do que o pacote exige.
3. **Reverse deps** — dependentes diretos (expansíveis) + seção
   transitiva (Enter no cabeçalho abre).

## Como funciona

Na inicialização o tui carrega o cache ou lê o instantâneo, valida o
documento (ids, contagem, nomes), calcula as arestas reversas e guarda
o índice em memória; o JSON bruto fica em cache gzipado em:

```
~/.cache/tui/index-v3.json.gz
```

Cache corrompido é colocado em quarentena (renomeado, nunca apagado em
silêncio) e o instantâneo é relido.

## Desenvolvimento

```sh
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test                                   # testes unitários + de fixture
cargo test --features web                    # inclui testes da API web
```

## Problemas comuns

- **"snapshot load failed"** — passe `--snapshot PATH` ou exporte
  `CYBERDECK_SNAPSHOT`; `./snapshot.json` também vale.
- **Instantâneo vazio** — o arquivo precisa de um documento JSON no
  esquema acima, com `package_count` igual ao tamanho da lista.
- **Dados antigos** — `R` relê o instantâneo, ou apague
  `~/.cache/tui/` e reinicie.
- **Sem cores** — `NO_COLOR` é respeitado (tema em cinza).

## Licença

GPL-3.0-or-later. Ver [LICENSE](LICENSE).
