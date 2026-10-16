# swmm-ruby

Wrapper Ruby do motor **EPA SWMM 5** (via FFI sobre a `libswmm5`) com um **contrato de entrada** e um **contrato de saída**.

```ruby
require "swmm"

result = Swmm.run(
  options:   { flow_units: "LPS", flow_routing: "DYNWAVE", start_date: "2026-03-24", end_date: "2026-03-24", end_time: "02:00", report_step: "00:10:00" },
  junctions: [{ name: "J1", elevation: 10, max_depth: 3 }],
  outfalls:  [{ name: "O1", elevation: 9, type: "FREE" }],
  conduits:  [{ name: "C1", from_node: "J1", to_node: "O1", length: 100, roughness: 0.013, in_offset: 0, out_offset: 0 }],
  xsections: [{ link: "C1", shape: "CIRCULAR", geom1: 0.4 }],
  timeseries: [{ name: "Q", points: [[0, 0], [0.5, 50], [1, 80], [2, 0]] }],
  inflows:   [{ node: "J1", series: "Q" }],
  report:    { nodes: "ALL", links: "ALL" }            # só o que estiver aqui vai para o .out
)

result.ok?                                   # => true
result.series(:links, "C1", :flow)           # => [15.2, 32.0, ...] (um valor por período, alinhado com result.times)
result.to_json                               # tudo, como dado puro
```

## Instalação

Ruby **4.0+** (`.ruby-version`: 4.0.7).

```sh
bundle install
brew install libomp        # só macOS (o clang da Apple não traz OpenMP)
rake swmm:build            # git clone + cmake da EPA (SWMM_VERSION=v5.2.4) -> vendor/swmm/libswmm5.*
```

Ou aponte `SWMM_LIB=/caminho/libswmm5.so` para uma lib já compilada. Alvo: SWMM **5.2.4**.

## Contrato de entrada — `Swmm::Input`

Um Hash (ou JSON) cujas chaves são as seções do `.inp` em minúsculas. **Cobre todas as 57 seções do SWMM 5.2**
(`options`, `junctions`, `conduits`, `subcatchments`, `lid_controls`, `controls`, `timeseries`…), então qualquer parâmetro do motor pode ser passado.
A referência de colunas de cada seção está em [`docs/input-contract.md`](docs/input-contract.md) (gerada do schema: `rake contract`).

| Forma | Exemplo |
|---|---|
| Tabela: Array de Hashes com colunas nomeadas | `junctions: [{ name: "J1", elevation: 10 }]` |
| Opções: Hash | `options: { flow_units: "LPS", routing_step: 30 }` |
| Palavras-chave: Hash | `evaporation: { monthly: [...12] }`, `report: { nodes: %w[J1 J2] }` |
| Objetos de várias linhas | `timeseries: [{ name: "Q", points: [[time, value], ...] }]`, `curves`, `patterns`, `transects`, `lid_controls`, `controls` |
| Escape: linha crua | `junctions: [["J1", 10, "*"]]` (tokens escritos como estão) |
| `.inp` já existente | `Swmm.run("modelo.inp")` |

- Datas: `Date`/`Time` ou `"2026-03-24"`; horas: `"HH:MM[:SS]"` ou segundos (Integer); `true/false` viram `YES/NO`; palavras-chave sem diferença de caixa.
- Colunas opcionais assumem o padrão do SWMM; colunas que dependem de outra (`outfalls.stage_data` quando `type` é FIXED/TIDAL/TIMESERIES) só existem nesse caso.
- Todos os erros vêm juntos, com caminho: `Swmm::InvalidInput#errors` → `[{path: "junctions[0].elevation", message: "must be a number, got \"x\""}]`.
  Para validar sem rodar: `Swmm.validate(hash)`. O `.inp` gerado: `Swmm::Input.new(hash).to_inp`.
- O motor lê no máximo 40 itens e 1023 caracteres por linha e descarta o resto em silêncio; o contrato recusa linhas assim.

## Contrato de saída — `Swmm::Result`

`Swmm.run` **sempre** devolve um `Result` (erros do motor não lançam exceção; contrato inválido sim).

```ruby
result.to_h  # =>
{
  status: "ok",                                  # "ok" | "error"
  swmm_version: "5.2.4",
  error: nil,                                    # { code: 200, message: "...", details: ["ERROR 209: undefined object X at line 14 of [CONDUIT] section: C1 J1 X ..."] }
  warnings: ["WARNING 02: maximum depth increased for Node J1"],
  continuity: { runoff: 0.0, flow_routing: -0.14, quality: 0.0 },   # erro de continuidade, % (nil se falhou)
  flow_instability: {},                          # { "C5" => 45, ... }: links que o relatório aponta como instáveis (reversões de vazão); {} se todos estáveis
  files: nil,                                    # { inp:, rpt:, out: } quando se usa dir:
  output: {
    flow_units: "LPS", start: "2026-03-24T00:00:00", report_step: 600, periods: 12,
    times: ["2026-03-24T00:10:00", ...],
    units: { nodes: { "depth" => "m", "total_inflow" => "LPS", ... }, links: {...}, subcatchments: {...}, system: {...} },
    subcatchments: { "S1" => { "rainfall" => [...], "runoff" => [...], "quality:TSS" => [...] } },
    nodes:         { "J1" => { "depth" => [...], "head" => [...], "volume" => [...], "lateral_inflow" => [...], "total_inflow" => [...], "overflow" => [...] } },
    links:         { "C1" => { "flow" => [...], "depth" => [...], "velocity" => [...], "volume" => [...], "capacity" => [...] } },
    system:        { "system" => { "total_inflow" => [...], "flooding" => [...], "outflow" => [...], ... } }
  }
}
```

Acessores: `ok?`, `error`, `warnings`, `continuity`, `continuity_ok?(tolerance: 5)`, `flow_instability`, `report` (texto do `.rpt`), `times`, `ids(kind)`, `variables(kind)`, `series(kind, id, variable)`,
`to_h(series: false)`, `to_json`, `to_csv(:nodes)` (`time,id,<variáveis>`). `kind` = `:subcatchments | :nodes | :links | :system`.
Os resultados vêm do `.out` binário, lido em Ruby e conferido contra a `libswmm-output` oficial da EPA.

`to_h`/`to_csv` leem o `.out` em bloco (um `unpack` por período) e, a partir de 250 mil valores por tipo, dividem a leitura entre **Ractors** que compartilham os bytes congelados do arquivo (1000 nós × 7 dias, 12 M de valores: `to_h` 4,8 s → 1,4 s; `to_csv` só ×1,3, porque o custo dele é montar as linhas). Ajuste ou desligue com `Swmm::OutputFile.ractors = 1` e `Swmm::OutputFile.parallel_from = ...`.

`Swmm.run(model, dir: "tmp/run1")` mantém `model.inp`, `model.rpt` e `model.out`; sem `dir:` ficam num diretório temporário removido ao fim.

## Várias simulações — `Swmm.run_many`

```ruby
results = Swmm.run_many([modelo_a, modelo_b, "modelo_c.inp"], workers: 8)   # => [Result, Result, Result], na ordem da entrada
```

Cada worker é uma thread com a sua **própria cópia do arquivo da lib** (a SWMM 5.2.4 não tem API reentrante: cada cópia tem estado global próprio) e as chamadas ao motor liberam o GVL.
Medido: 8 simulações de 200 nós por 7 dias, 13,0 s em sequência → 1,9 s (×6,8, 14 núcleos), resultados idênticos. As cópias são criadas uma vez, reaproveitadas e removidas ao fim do processo.
Todos os contratos são validados antes de rodar qualquer coisa (`InvalidInput`); só usa arquivos temporários (para `dir:` use `Swmm.run`). Exige a lib como arquivo (`SWMM_LIB` ou `rake swmm:build`). Testado em macOS (arm64) e Linux (aarch64, glibc): em Linux, 8 simulações ×3,8.
Dentro de **uma** simulação não há ganho: `threads:` do SWMM quase não escala (4 threads: 6,6 s → 5,5 s com o dobro de CPU).

## Cuidados

- **`ok?` só diz que o motor terminou**, não que o modelo é bom: um modelo instável termina sem erro (visto: erro de continuidade de −258 %). Use `continuity_ok?` (5 % é uma meta prática da literatura, não uma regra da EPA; `tolerance:` ajusta) e `flow_instability`; continuidade baixa também não garante estabilidade hidráulica.
- **`[REPORT]` decide o que é gravado**: só subcatchments/nós/condutas listados (`"ALL"` ou ids) entram em `output`; o sistema sempre entra. Sem isso, `result.ids(:nodes)` fica vazio.
- O motor tem estado global: **uma simulação por vez por cópia da lib** (há um `Mutex` por cópia). `Swmm.run` usa uma cópia; para paralelismo use `Swmm.run_many` (abaixo). Um crash dentro da lib C derruba o processo.
- Caminhos relativos em `files`/`timeseries file` são resolvidos pelo motor a partir da pasta do `.inp`; com `Swmm.run(hash)` use caminhos absolutos.
- O `.out` inteiro fica em memória; ok para centenas de MB.

## Testes

```sh
rake test      # sem libswmm5, os testes que precisam do motor são pulados
```

`test/conformance_test.rb` roda um modelo que usa **todas** as seções e variantes de cada coluna condicional (tipos de exutório, reservatório, divisor, vertedouro, seções transversais…) no motor real.
