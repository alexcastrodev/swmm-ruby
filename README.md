# swmm-ruby

Roda simulações do **EPA SWMM 5** a partir de Ruby (FFI sobre a `libswmm5`).

- **Entrada:** um modelo SWMM como Hash/JSON (as seções do `.inp` em minúsculas) ou o caminho de um `.inp`; **ou** os arquivos que o SWMM já gerou (`.rpt` e `.out`).
- **Saída:** um `Swmm::Result` com status, erro do motor, avisos, erro de continuidade e todas as séries temporais salvas, exportável para Hash, JSON e CSV.

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
result.series(:links, "C1", :flow)           # => [15.2, 32.0, ...] um valor por período, alinhado com result.times
result.to_json                               # tudo, como dado puro
```

## Instalação

Ruby **4.0+**.

```sh
bundle install
brew install libomp        # só macOS (o clang da Apple não traz OpenMP)
rake swmm:build            # clona e compila o SWMM da EPA (SWMM_VERSION=v5.2.4) -> vendor/swmm/libswmm5.*
```

Ou aponte `SWMM_LIB=/caminho/libswmm5.so` para uma lib já compilada. Alvo: SWMM **5.2.4**.
Em Linux, sem instalar nada: `docker build -t swmm-ruby . && docker run --rm swmm-ruby` (compila a lib e roda os testes).

## Entrada — `Swmm::Input`

Um Hash (ou JSON) cujas chaves são as seções do `.inp` em minúsculas. Cobre as 57 seções do SWMM 5.2; as colunas de cada uma estão em [`docs/input-contract.md`](docs/input-contract.md) (gerado do schema: `rake contract`).

| Forma | Exemplo |
|---|---|
| Tabela: Array de Hashes | `junctions: [{ name: "J1", elevation: 10 }]` |
| Opções: Hash | `options: { flow_units: "LPS", routing_step: 30 }` |
| Palavras-chave: Hash | `evaporation: { monthly: [...12] }`, `report: { nodes: %w[J1 J2] }` |
| Objetos de várias linhas | `timeseries: [{ name: "Q", points: [[time, value], ...] }]`, `curves`, `patterns`, `transects`, `lid_controls`, `controls` |
| Linha crua (escape) | `junctions: [["J1", 10, "*"]]` |
| `.inp` existente | `Swmm.run("modelo.inp")` |

- Datas: `Date`/`Time` ou `"2026-03-24"`. Horas: `"HH:MM[:SS]"` ou segundos. `true/false` viram `YES/NO`. Colunas opcionais assumem o padrão do SWMM.
- Contrato inválido levanta `Swmm::InvalidInput`, com **todos** os erros e o caminho de cada um: `[{path: "junctions[0].elevation", message: "must be a number, got \"x\""}]`.
- `Swmm.validate(hash)` valida sem rodar; `Swmm::Input.new(hash).to_inp` devolve o `.inp` gerado.

## Saída — `Swmm::Result`

`Swmm.run` **sempre** devolve um `Result`: erro do motor vem em `result.error`, não como exceção.

```ruby
result.to_h  # =>
{
  status: "ok",                                  # "ok" | "error"
  swmm_version: "5.2.4",
  error: nil,                                    # { code: 200, message: "...", details: ["ERROR 209: undefined object X at line 14 ..."] }
  warnings: ["WARNING 02: maximum depth increased for Node J1"],
  continuity: { runoff: 0.0, flow_routing: -0.14, quality: 0.0 },   # erro de continuidade, % (nil se falhou; um valor não finito, como NaN, vira null no JSON)
  flow_instability: {},                          # { "C5" => 45, ... } links instáveis segundo o relatório; {} se todos estáveis
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

Acessores: `ok?`, `error`, `warnings`, `continuity`, `continuity_ok?(tolerance: 5)`, `flow_instability`, `node_flooding`, `analysis_options`, `report_start`, `report` (texto do `.rpt`), `times`, `ids(kind)`, `variables(kind)`, `series(kind, id, variable)`, `to_h(series: false)`, `to_json`, `to_csv(:nodes)` (`time,id,<variáveis>`). `kind` = `:subcatchments | :nodes | :links | :system`; um `kind`, id ou variável que os resultados não têm levanta `Swmm::UnknownObject` (um `Swmm::Error`).

### Alagamentos — `node_flooding`

A tabela "Node Flooding Summary" do relatório, um Hash por nó que alagou (`[]` se nenhum alagou):

```ruby
result.node_flooding  # =>
[{ node: "J1", hours: 1.76, max_rate: 103.07, max_elapsed: 3600, max_time: 2026-03-24 01:00:00 UTC, volume: 354.0, max_ponded_depth: 0.0 }]
```

- `max_rate` na unidade de vazão; `volume` na unidade de volume de `units` (m3 ou ft3; o relatório imprime 10^6 L ou 10^6 gal); `max_ponded_depth` em m ou ft.
- O relatório conta o "days hr:min" do máximo a partir do início do relatório (`REPORT_START`), não do início da simulação: `max_elapsed` são esses segundos e `max_time` é `report_start + max_elapsed` (`nil` sem `.out`).
- `report_start` não está no relatório: sai do início que o `.out` grava. É exato quando o `REPORT_START` é o início da simulação ou fica um número inteiro de passos de relatório (pelo menos dois) depois dele; nos outros casos os arquivos não o distinguem de um início anterior e `report_start` sai até um passo de relatório mais cedo.
- `analysis_options` são os valores do bloco "Analysis Options" do relatório: `{ flow_units:, start:, end:, report_step: }` (`nil` para o que o relatório não imprime).

`Swmm.run(model, dir: "tmp/run1")` mantém `model.inp`, `model.rpt` e `model.out`; sem `dir:` ficam num diretório temporário removido ao fim.

## A partir de arquivos já gerados — `Swmm.read`

```ruby
result = Swmm.read(rpt: "modelo.rpt", out: "modelo.out")   # o mesmo Result de Swmm.run
```

Para arquivos gerados pela interface do SWMM, pelo `swmm5` de linha de comando ou por `Swmm.run(dir:)`. **Não roda o motor e não precisa da `libswmm5`.**

- `rpt:` é obrigatório. `out:` é opcional: uma simulação que falhou antes de gravá-lo vem sem `output`. O `.inp` não é necessário.
- Versão, erro, avisos, `flow_instability` e as séries saem dos próprios arquivos. O código de erro vem do `.out`; sem `.out`, erros de entrada (2xx) viram `200`, como o motor devolve.
- `continuity` vem das linhas `Continuity Error (%)` do `.rpt`, com 3 casas decimais (no `Swmm.run` vem do motor, em `float`). Um bloco que o relatório não imprime conta como `0.0`.
- A versão sai do `.out` ou, sem ele, do cabeçalho do relatório da EPA (`Build 5.2.4`) ou da OWA (`VERSION v5.2.1`).
- Arquivo ausente levanta `Errno::ENOENT`; `.rpt` que não foi escrito pelo SWMM (sem o cabeçalho `STORM WATER MANAGEMENT MODEL`), `Swmm::ReportFormatError`; `.out` que não é do SWMM, `Swmm::OutputFormatError`.
- Um `.out` de outra simulação levanta `Swmm::MismatchedFiles`: a unidade de vazão, o passo de relatório, o início e o fim que o relatório imprime têm de bater com o `.out`. Outra execução do mesmo modelo não é distinguível.

## Várias simulações — `Swmm.run_many`

```ruby
results = Swmm.run_many([modelo_a, modelo_b, "modelo_c.inp"], workers: 8)   # => [Result, Result, Result], na ordem da entrada
```

Cada worker é uma thread com a sua própria cópia do arquivo da lib (o motor tem estado global; a 5.2.4 não tem API reentrante). Levanta `ArgumentError` se `workers` for menor que 1 ou se a entrada não for uma lista (um Hash de modelo sozinho não é). Valida todos os contratos antes de rodar qualquer um, se um worker levanta exceção os outros param e a exceção chega a quem chamou, usa só arquivos temporários (para `dir:` use `Swmm.run`) e exige a lib como arquivo (`SWMM_LIB` ou `rake swmm:build`). Dentro de **uma** simulação não há paralelismo.

`to_h` e `to_csv` leem saídas grandes (a partir de 250 mil valores por tipo) em Ractors; para ajustar ou desligar: `Swmm::OutputFile.ractors = 1`, `Swmm::OutputFile.parallel_from = ...`.

## Cuidados

- **`ok?` só diz que o motor terminou**, não que o modelo é bom: um modelo instável termina sem erro. Confira `continuity_ok?` e `flow_instability`.
- **`[REPORT]` decide o que é gravado**: só subcatchments, nós e condutas listados (`"ALL"` ou ids) entram em `output`; o sistema sempre entra. Sem isso, `result.ids(:nodes)` fica vazio.
- Caminhos relativos em `files` e `timeseries file` são resolvidos pelo motor a partir da pasta do `.inp`; com `Swmm.run(hash)` use caminhos absolutos.
- O motor lê no máximo 40 itens e 1023 **bytes** por linha e descarta o resto em silêncio; o contrato recusa linhas assim. Também recusa nomes e linhas que começam com `[` (o motor leria como início de seção) e qualquer texto com quebra de linha ou NUL.
- **Nomes de objeto não podem ter espaços** (nem as referências a eles): o motor conta os objetos numa primeira passada que ignora aspas, então um nome como `"J 1"` nunca poderia ser usado. Caminhos, tags, rótulos e nomes de regra podem ter espaços (vão entre aspas). Textos devem ser UTF-8: UTF-16, Latin-1 e binário com UTF-8 válido são convertidos; o resto é recusado. Chaves que só diferem na caixa (`junctions` e `JUNCTIONS`) são um erro, não uma sobrescrita. Linhas cruas (Array) não distinguem nome de rótulo, então um nome com espaço passa pelo contrato e o motor o recusa.
- **Bugs conhecidos do motor (SWMM 5.2.4, sem correção na gem):** (1) em cerca de 1 de cada 3 janelas de simulação o último período de relatório não é gravado (contorno: terminar a simulação 1 segundo depois, `end_time: "13:00:01"`); (2) em Linux, um modelo cujo subcatchment usa um snowpack com superfície de área zero dá, em ~2% das execuções idênticas, um resultado errado (continuidade `NaN`; contorno: repetir a simulação). Os dois terminam com `ok? == true`. Causa, como reconhecer e o diff de uma linha de cada um: [`docs/known-issues.md`](docs/known-issues.md).
- O `.out` inteiro fica em memória. Um crash dentro da lib C derruba o processo.

## Testes

```sh
rake test      # sem libswmm5, os testes que precisam do motor são pulados
```

- [`.github/workflows/ci.yml`](.github/workflows/ci.yml): a CI compila a `libswmm5` e roda a suíte em Ubuntu (x86_64) e macOS (arm64), e falha se a lib não carregar.
- [`docs/test-plan.md`](docs/test-plan.md): plano de teste, cobertura e riscos.
- [`docs/results.md`](docs/results.md): medições de desempenho e verificações por plataforma.
