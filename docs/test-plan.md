# Plano de teste

Escopo: a gem `swmm-ruby` (Ruby 4.0.7) — contrato de entrada (`Input`/`Schema`/`Types`), motor (`Engine`, `Swmm.run`, `Swmm.run_many`), leitor do `.out` (`OutputFile`, inclusive leitura em Ractors) e contrato de saída (`Result`, `to_h`/`to_json`/`to_csv`).
Plataformas: macOS arm64, Linux aarch64 (Docker) e Linux x86_64 (glibc). Motor: `libswmm5` 5.2.4.

## 1. Cobertura atual (antes das frentes A–D)

| arquivo | o que garante |
|---|---|
| `input_test.rb` | validação, mensagens com caminho, `.inp` gerado, JSON de ida e volta |
| `conformance_test.rb` | modelo que usa **todas** as seções e variantes condicionais, no motor real |
| `run_test.rb` | contrato de saída, erros do motor, `dir:`, `run_many`, continuidade, modelo instável |
| `output_file_test.rb` | arquivo inválido/truncado, `series` × `all_series`, leitura em Ractors |
| `csv_test.rb` | conteúdo do CSV contra oráculo independente, quoting, caminho em Ractors |
| `ractor_test.rb` | módulo FFI congelado é compartilhável e um Ractor chama o motor |
| `result_test.rb` | parser do relatório (instabilidade, alagamentos, opções de análise), tolerância de continuidade, `kind` desconhecido, `.rpt` que não é do SWMM, versão do cabeçalho EPA/OWA |
| `known_engine_bugs_test.rb` | os dois bugs conhecidos do motor (`docs/known-issues.md`): janelas que perdem o último período e heap cheio de `0xFF` contra a leitura de memória não inicializada do snowpack, ambos `skip` (`SWMM_SHOW_BUGS=1` os executa); o contorno (terminar 1 segundo depois) roda sempre |
| `input_parser_test.rb` | `Swmm::Input.parse`/`read`: `.inp` como a interface escreve (comentários, CRLF, BOM, tabs, aspas, linhas curtas, séries com e sem data, continuações), opções tipadas, linha crua quando não encaixa, `only:`, erros com a linha, Windows-1252, ida e volta do contrato inteiro e o mesmo resultado no motor |
| `read_test.rb` | `Swmm.read` (`rpt`/`out` → `Result`): igual ao `Swmm.run`, continuidade com poluentes, erro sem `.out`, código de erro no epílogo, só o `.rpt`, arquivos inválidos, `.out` de outra simulação, horário do máximo dos alagamentos com e sem `REPORT_START` (e o limite do `report_start`), sem motor nem lib |

## 2. Riscos e lacunas

| # | risco | evidência / hipótese | prioridade |
|---|---|---|---|
| R1 | **Contrato de entrada deixa passar texto que o `.inp` interpreta como estrutura** | **Comprovado:** o id `[OUTFALLS]` valida sem erro e gera a linha `[OUTFALLS] 10 3 0 0 0`; o motor só recusa depois (`ERROR 200`, genérico). Outros candidatos: `[` no início de qualquer token, espaços/Unicode/NBSP, números extremos (NaN, Infinity, 1e400), linhas longas | alta |
| R2 | `OutputFile` com bytes hostis ou corrompidos | contagens enormes no cabeçalho (`Array.new(n)`, `read_ids`) podem alocar sem limite ou travar; deve levantar só `OutputFormatError` | alta |
| R3 | Fidelidade dos números | o projeto afirma (ver `docs/results.md`) que o leitor foi conferido com a `libswmm-output` da EPA, mas nenhum teste da suíte usa um oráculo externo (o `Example1.out` da EPA e `swmm_getSavedValue` do próprio motor servem) | alta |
| R4 | Concorrência e ciclo de vida | `run_many` sob estresse, erro dentro de um worker, `workers` inválido, falha seguida de sucesso (estado global do motor), `Swmm.run` em várias threads, Ractors criados de várias threads, restauração de `Warning[:experimental]` | alta |
| R5 | Ambiente | avisos do Ruby (`-w`), cwd diferente, `SWMM_LIB` inexistente/ruim, biblioteca ausente, limpeza de temporários | média |
| R6 | Estabilidade do contrato de saída | `to_h`/`to_json` sem teste de formato fixo (golden) | média |
| R7 | Desempenho | sem regressão automática; testes de tempo ficam **fora** da suíte (instáveis) | baixa |

## 3. Estratégia

- **Sem motor** (rápidos, sempre rodam): contrato de entrada, parser de relatório, leitor do `.out` com bytes sintéticos.
- **Com motor real** (`NeedsEngine`): integração, fidelidade, concorrência. Sem a lib, são pulados; **qualquer pulado numa rodada de verificação invalida o resultado**.
- **Adversarial/fuzz determinístico:** sementes fixas, poucas centenas de casos, cada arquivo em segundos.
- **Ambiente:** suíte completa no Mac, em Docker (`docker build -t swmm-ruby . && docker run --rm swmm-ruby`) e no x86_64. A CI (`.github/workflows/ci.yml`) roda em Ubuntu x86_64 e macOS arm64 a cada push e pull request, compila a lib e falha se ela não carregar (senão os testes de motor seriam pulados e o job ficaria verde).
- Nenhuma asserção depende de tempo ou de número de núcleos.

## 4. Frentes (cada uma num arquivo novo)

| frente | arquivo | cobre | agente |
|---|---|---|---|
| A — entrada adversarial | `test/input_adversarial_test.rb` | R1: injeção por id/token, Unicode, números extremos, limites de linha (40 itens / 1023 caracteres), chaves string/símbolo, JSON | Opus, effort `high` |
| B — `.out` hostil | `test/output_fuzz_test.rb` | R2: truncamento, bit flips, cabeçalho alterado; só `OutputFormatError`, memória e tempo limitados | Opus, effort `high` |
| C — fidelidade | `test/fidelity_test.rb` | R3, R6: `Example1.out` da EPA, `swmm_getSavedValue`, tabelas do `.rpt`, unidades, datas; golden do `to_h` | Sonnet, effort `high` |
| D — concorrência e ciclo de vida | `test/concurrency_test.rb` | R4 | Sonnet, effort `high` |
| E — ambiente | (verificação, sem arquivo) | R5: `ruby -w`, cwd, `SWMM_LIB`, Docker, x86_64 | eu |

Regras para quem testa:
1. Só cria o próprio arquivo de teste; **não altera `lib/`**, README, Dockerfile nem testes existentes; sem commit.
2. Bug encontrado: relatar com reprodução mínima e deixar o teste correspondente com `skip "BUG: ..."` (a suíte fica verde e a reprodução fica no código).
3. Rodar o próprio arquivo isoladamente durante o trabalho (`bundle exec ruby -Ilib -Itest test/<arquivo>`); a suíte completa só no fim.
4. Testes determinísticos, rápidos (alvo: arquivo inteiro em menos de 10 s) e sem tempo como asserção.

## 5. Critérios de saída

- Suíte completa verde no Mac, no Docker aarch64 e no x86_64, **0 pulados** além dos marcados como `BUG`.
- Todo risco acima com teste ou com decisão registrada (corrigir / aceitar / documentar).
- Achados classificados por severidade e levados ao dono do projeto antes de qualquer correção em `lib/`.

## 6. Resultados (2026-10-16)

Suíte: **203 execuções, 30 523 asserts, 0 falhas, 2 pulados**, em macOS arm64, Linux aarch64 (Docker, 3 rodadas) e Linux x86_64 (Debian 13, 3 rodadas), Ruby 4.0.7, com a `libswmm5` da EPA sem alterações. Depois de `node_flooding` e das verificações do `Swmm.read` (2026-10-22): **214 execuções, 30 594 asserts, 0 falhas, 2 pulados**; com o leitor de `.inp`: **228 execuções, 30 633 asserts, 0 falhas, 2 pulados**, só em Linux aarch64 (Ruby 4.0.7). Os 2 pulados são os dois bugs conhecidos do motor (`KnownEngineBugsTest`, [`known-issues.md`](known-issues.md)): descrevem o comportamento correto e falham com o motor como é lançado; `SWMM_SHOW_BUGS=1` os executa. Todos os outros defeitos da lista abaixo foram corrigidos.

| frente | arquivo | testes | defeitos reproduzidos |
|---|---|---|---|
| A — entrada | `input_adversarial_test.rb` | 33 | 12 (4 altos, 4 médios e IN-9, IN-10, IN-11 **corrigidos**; IN-12 é bug do Ruby) |
| B — `.out` hostil | `output_fuzz_test.rb` | 22 | 9 (**todos corrigidos**) |
| C — fidelidade | `fidelity_test.rb` | 39 | 1 + 2 comportamentos do motor |
| D — concorrência | `concurrency_test.rb` | 51 | 8 (1 médio e 7 baixos, **todos corrigidos**) |

Fidelidade: todos os valores lidos do `.out` coincidem com três oráculos independentes (o `Example1.out` e os números de `test_output.cpp` da EPA, as tabelas do relatório do motor e `swmm_getSavedValue`): 10 692 valores do exemplo da EPA, 516 de `Fixtures.base` e 4 488 de `Fixtures.full`, sem divergência. A afirmação sobre a `libswmm-output` agora tem teste (R3).

Defeitos, por prioridade. IN-1 a IN-8, OUT-1 a OUT-7 e D-1 a D-8 foram **corrigidos** em 2026-10-16 (validação de entrada em `types.rb`/`input.rb`; checagens de tamanho, códigos e datas no leitor `output_file.rb`) e reverificados com os mesmos casos, em macOS, Linux aarch64 e Linux x86_64; os demais seguem abertos, cada um com seu teste `skip "BUG: …"`. Os marcados † foram reproduzidos também pelo líder do teste.

| id | sev. | resumo | onde |
|---|---|---|---|
| IN-1 † ✔ | alta | nome entre aspas que começa com cabeçalho de seção (`"[JUNCTIONS] x"`) passa na validação e derruba o processo (SIGSEGV, saída 139) | `types.rb` `word` |
| IN-2 † ✔ | alta | nome que começa com `[` remove um objeto em silêncio (`ok`, mas o nó some) | `types.rb` |
| IN-3 † ✔ | alta | limite de 1023 conta caracteres, o motor conta bytes: o motor corta a linha e cria um objeto que ninguém escreveu | `input.rb` |
| IN-4 † ✔ | alta | quebras de linha e cabeçalhos entram por `controls`, ações de regra e título (criam nós) | `input.rb` |
| OUT-1 † ✔ | alta | contagem corrompida no cabeçalho do `.out`: a memória cresce com o valor (29 → 403 MB com 1 M → 50 M; 2³¹−1 pede GB) e termina em `IndexError`; vale também para `Swmm.read` | `output_file.rb` `read_ints` |
| IN-5 ✔ | média | nomes com espaço nunca funcionam (o motor ignora aspas na primeira passada) | `types.rb` |
| IN-6 ✔ | média | NUL aceito em ids; o motor corta a linha ali (fator de escala ignorado em silêncio) | `types.rb` |
| IN-7 ✔ | média | `validate` levanta (em vez de listar erros) com strings binárias, UTF-16 ou UTF-8 inválido | `input.rb`, `types.rb` |
| IN-8 ✔ | média | chaves que diferem só na caixa (`junctions`/`JUNCTIONS`) perdem dados em silêncio | `input.rb` |
| OUT-2..7 ✔ | média | `OutputFile.new` levanta `ArgumentError`, `NoMethodError`, `IndexError` ou `FloatDomainError` em vez de `OutputFormatError` (contagens/ids/códigos de variável/datas inválidos); códigos de variável negativos são aceitos com nomes errados | `output_file.rb` |
| D-1 ✔ | média | um filho criado com `fork` apaga as cópias da lib do pai ao sair (`at_exit` herdado); o `run_many` seguinte falha com `ENOENT` | `engine.rb` |
| MOTOR-2 † | média | **bug conhecido, sem patch (decisão do projeto)**: o motor dá resultado diferente em Linux (~2% das execuções: continuidade de runoff `NaN`, runoff do S1 zerado) quando um subcatchment usa snowpack com superfície de área zero: `imelt[]` não inicializado em `snow.c`. Causa provada com valgrind; correção de uma linha em `docs/known-issues.md`; a gem exporta a continuidade `NaN` como `null` e `continuity_ok?` dá `false` | libswmm5 |
| MOTOR-1 † | média | **bug conhecido, sem patch (decisão do projeto)**: o motor não grava o último período em ~1 de cada 3 janelas (`TotalDuration` truncado em ponto flutuante, `project.c`); igual ao `swmm_run` puro, em qualquer plataforma. Contorno verificado (terminar 1 segundo depois) e correção de uma linha em `docs/known-issues.md` | libswmm5 |
| D-2..8 ✔ | baixa | `run_many`: `workers: 0` devolvia `[nil, nil, nil]`; os outros workers não paravam após uma exceção; a exceção era impressa e relançada; `run_many(hash)` iterava pares; `nil`/`""` não eram validados; corrida em `Warning[:experimental]`; `SWMM_LIB` inválido tratado diferente em `run` e `run_many` | `swmm.rb`, `engine.rb`, `output_file.rb` |
| IN-9, IN-10, IN-11, OUT-8, OUT-9, C-1 ✔ | baixa | Symbol com formato de data levantava `TypeError`; inteiro maior que o `Float` era aceito (o motor lê infinito); subclasse de `Numeric` sem `to_f` levantava `TypeError` em `validate`; códigos de unidade negativos eram aceitos (índice pelo fim da tabela); `OutputFile.new(nil)` levantava `NoMethodError` (agora `TypeError`); `continuity` com ruído de float32 | `types.rb`, `output_file.rb`, `engine.rb` |
| IN-12 | baixa | arrays aninhados em ~10 000 níveis derrubam o próprio Ruby 4.0.7 (SIGILL em `Array#inspect`); bug do interpretador, o limite de profundidade padrão do `JSON.parse` (100) evita | Ruby |
| NOVO-1 ✔ | baixa | com continuidade `NaN` (resultado do MOTOR-2) `Result#to_json` levantava `JSON::GeneratorError`; agora `to_h`/`to_json` exportam `null` para valores não finitos, e `result.continuity` mantém o `NaN` (então `continuity_ok?` continua `false`) | `result.rb` |

Comportamentos do motor (sem defeito do wrapper): `OutputFile#start` é um período antes do primeiro resultado quando `report_start` é posterior; o `.rpt` gerado pela gem não tem as tabelas de séries por nó/link porque a gem não chama `swmm_report`.
