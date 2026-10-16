# Medições e verificações

Resultados de testes e de desempenho feitos durante o desenvolvimento. O README descreve só o que a gem faz; os números ficam aqui. Datas: 2026-10-16.

## Como foi medido

- **Modelo sintético:** rede em cadeia de *n* nós, onda dinâmica (`DYNWAVE`), passo de roteamento de 30 s, 7 dias, passo de relatório de 5 min (2016 períodos), `[REPORT]` com todos os nós e links. Para 1000 nós o `.out` tem 89 MB e 12 M de valores só nos nós.
- **Máquinas:** macOS arm64 com 14 núcleos (Ruby 4.0.7); Docker Desktop em Linux aarch64 (VM, 14 vCPUs); Linux x86_64 Debian 13 com 12 núcleos lógicos, em contêiner limitado a 8 CPUs e com outros serviços rodando.
- Em geral uma amostra por medida, depois de um aquecimento (as de `to_csv` com Ractors em macOS são o melhor de 3). Servem como ordem de grandeza, não como garantia.

## Uma simulação de uma semana

| nós | `.out` | motor | leitura completa (`to_h`) antes das otimizações | `to_csv(:nodes)` antes |
|---|---|---|---|---|
| 20 | 2 MB | 0,17 s | 0,14 s | 0,18 s |
| 200 | 18 MB | 1,6 s | 1,3 s | 1,8 s |
| 1000 | 89 MB | 6,8 s | 6,4 s | 14,9 s |

- O motor não escala por dentro: `threads:` do SWMM com 1 / 4 / 8 threads levou 6,6 / 5,5 / 8,0 s, usando 6,6 / 10,3 / 18,7 s de CPU. O ganho de paralelismo vem de **várias simulações**, não de acelerar uma.
- Uma simulação não se divide no tempo: cada passo depende do anterior (e do hotstart do dia anterior).
- Chamar o motor com `blocking: true` (libera o GVL) não deixou um run único mais lento: 6,65 s de ponta a ponta com 1000 nós.

## `Swmm.run_many`

8 simulações de 200 nós por 7 dias, uma cópia da lib por worker, resultados idênticos aos da execução em sequência:

| plataforma | sequencial | `run_many` | ganho |
|---|---|---|---|
| macOS arm64 (14 núcleos) | 13,0 s | 1,9 s | ×6,8 |
| Linux aarch64 (Docker Desktop) | 15,4 s | 4,1 s | ×3,8 |
| Linux x86_64 (contêiner com 8 CPUs, máquina com serviços) | 26,3 s | 7,3 s | ×3,6 |

- O ganho menor em Linux não foi isolado (limite de CPU do contêiner, VM, serviços no host ou núcleos lógicos são candidatos).
- Protótipo só do motor (`swmm_run`): threads ×5,6 a ×6,2; Ractors ×7,4 (uma amostra). Threads foram mantidas por serem mais simples.
- Cópias da `.so` com nomes diferentes têm estado global independente em macOS e em Linux/glibc. A `libswmm5` 5.2.4 não exporta API reentrante (sem `swmm_alloc`/handle de projeto).

## Leitura do `.out` e Ractors

Leitura em bloco: um `unpack` por período em vez de um por valor. A etapa cara é `OutputFile.clean` (`format("%.7g")` + `to_f`), não o `unpack`.

`to_h` com 1000 nós (12 M de valores), por número de Ractors:

| Ractors | macOS | Linux aarch64 | Linux x86_64 |
|---|---|---|---|
| 1 | 4,78 s | 6,43 s | 10,24 s |
| 2 | 3,39 s | 4,16 s | 5,84 s |
| 4 | 1,69 s | 2,31 s | 3,94 s |
| 6 | 1,42 s | 2,07 s | 3,35 s |
| 8 | 1,31 s | 2,37 s | 3,20 s |

Padrão adotado: `min(CPUs, 6)`; a leitura paralela entra a partir de 250 mil valores por tipo (mesmo com 0,1 M de valores já ganha, mas são milissegundos).

`to_csv(:nodes)` com 1000 nós (131 MB de CSV):

| versão | macOS | Linux x86_64 |
|---|---|---|
| original (por valor) | 14,9 s | n/m |
| leitura em bloco + linhas por `join` | 6,8 s | 10,95 s |
| linhas por período, 1 Ractor | 6,1 s | 10,4 s |
| linhas por período, 6 Ractors (padrão) | 1,8 s na chamada (2,5 s no processo inteiro) | 3,7 a 3,9 s |

- Pico de memória do `to_csv(:nodes)` com 1000 nós: 497 MB sequencial e 632 MB com Ractors (só carregar o `.out`: 106 MB).
- O CSV novo é byte a byte idêntico ao antigo em 8 combinações (200 e 1000 nós × nós e links × 1 e 6 Ractors).

Alternativas de `clean` descartadas (mesmo resultado que `format("%.7g")` exigido):

| alternativa | ganho | motivo |
|---|---|---|
| aritmética exata (desempate para par, `format` só como reserva) | ×1,5 | pouco para o código extra |
| `Float#round` com dígitos significativos | ×1,7 a ×2,7 | desempata para cima e erra valores minúsculos |
| memorizar por valor | ×1,1 | só 44% dos valores são distintos, mas o custo da busca no hash anula o ganho |

Em Ractors: o módulo FFI precisa ser criado e congelado na Ractor principal (`FFI::Library` criada dentro de um Ractor levanta `Ractor::IsolationError`); `Fiddle` não funciona em Ractors; o Ruby 4.0.7 ainda imprime "Ractor API is experimental" (suprimido em volta do `Ractor.new`).

## Defeitos conhecidos do motor (sem patch)

Dois defeitos da `libswmm5` 5.2.4 da EPA têm causa raiz identificada no código C. A gem **não os corrige** (decisão do projeto): ficam documentados em [`known-issues.md`](known-issues.md), com sintoma, contorno, causa e o diff de uma linha de cada. Estas são as medições por trás desse documento.

**Último período perdido (`project.c`).** `TotalDuration = floor((EndDateTime - StartDateTime) * 86400)`: cada data é um número perto de 4,5e4 mais a fração do dia, arredondado a um `double`; a diferença pode sair um pouco abaixo do intervalo real (11:00 a 13:00 de 2022-11-27: 7199,9999995809 s) e o `floor` perde um segundo inteiro, deixando o último instante de relatório fora da simulação. Independe de plataforma. Em 300 janelas aleatórias de 2 horas, 98 perdiam o último período (12 esperados, 11 saídos). Com uma tolerância de 1 ms na conta (a correção candidata), 300 de 300 saíam com 12 períodos, e as 202 janelas que já estavam certas produziam `.out` idêntico (`cmp`). A regra que prevê quais janelas perdem (a conta em ponto flutuante) concordou em 900 de 900 janelas. Em 20 000 janelas aleatórias de 1 a 40 horas a fórmula da 5.2.4 erra em 33,8%, a do ramo `bug_fixes` e do fork OWA em 6,8% e a candidata em 0. Contorno: terminar a simulação um segundo depois; funcionou em 98 de 98 janelas problemáticas, com os 11 primeiros períodos idênticos.

**Resultado diferente entre execuções idênticas (`snow.c`).** O `snowpack` vem de `malloc` e o `snow_initSnowpack` inicializa tudo menos `imelt[]`, que só é escrito para superfícies com área maior que zero. Com a fração plowável 0 do modelo de teste, `imelt[0]` fica com o que havia no heap e `imelt[i] +=` o lê; se for `NaN`, `NaN * 0` é `NaN` e contamina o runoff e a continuidade. No Linux o `glibc` entrega blocos reciclados (~2% das execuções); no macOS os blocos pequenos vêm zerados (0 em 1200). Provado com `valgrind --track-origins=yes` (todos os erros nascem em `snow.c:135`) e com `--malloc-fill=0xff`. Linha de base, execuções do modelo completo: x86_64 16 erradas em 600 (2,7%), aarch64 de 1,5% a 2,4%. Com a linha candidata (`imelt[i] = 0.0` no `snow_initSnowpack`): aarch64 0 de 1800 e x86_64 0 de 600. Upstream: nada encontrado.

O teste do bug 2 (`known_engine_bugs_test.rb`) enche de `0xFF` blocos que libera, para o `malloc` os reciclar: falha em ~55% das execuções no aarch64 e na maioria no x86_64 (24 execuções por teste tornam a falha quase certa); no macOS o `malloc` não recicla e o teste não tem o que pegar. Outro defeito latente no mesmo arquivo (`sba[]` e `sbws[]` também não são inicializados) só é lido depois de um `USE HOTSTART` e não foi investigado.

## Qualidade do modelo

Três modelos propositalmente instáveis terminaram sem erro (`ok? == true`) com erro de continuidade de −258 %, −111 % e −47 % e links apontados em "Highest Flow Instability Indexes" (índices de 43, 23, 21…). Por isso o `Result` expõe `continuity_ok?` e `flow_instability`. O limite de 5 % é uma meta prática de documentação de fornecedores (Bentley, GeoSWMM), não uma regra da EPA; não há limite definido para o índice de instabilidade.

## Verificações

- **Suíte:** verde em macOS arm64, Linux aarch64 (Docker) e Linux x86_64 (Debian 13), Ruby 4.0.7, sem testes pulados. A contagem atual e o estado de cada frente estão em [`test-plan.md`](test-plan.md).
- **Leitor do `.out`:** o README original afirmava conferência contra a `libswmm-output` da EPA; essa conferência não está na suíte (risco R3 do plano de teste).
- **Docker:** imagem de teste de 1,78 GB (base `ruby:4.0.7` completa) reduzida para 324 MB (aarch64) e 298 MB (x86_64) com build em dois estágios e base `-slim`; a `-slim` precisa do `libgomp1`, sem ele o motor não carrega e os testes são pulados.
