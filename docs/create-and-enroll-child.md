# 새 child 만들기와 scalex-federation 연결하기

이 절차는 외부 팀의 `sample-poc` repository를 `scalex-sample-poc` release로 등록하는
예시다. 애플리케이션 기능 구현이나 image build pipeline은 범위에 포함하지 않는다.
먼저 [child 최소 계약](scalex-federation-child-contract.md)을 확인한다.

## 1. 이름과 소유권 결정

다음 네 값을 먼저 정한다.

```text
repository URL: https://github.com/<owner>/sample-poc.git
chart path:     chart
release ID:     scalex-sample-poc
namespace:      scalex-sample-poc
```

현재 Federation AppProject가 `scalex-*` namespace만 허용하므로 release ID와 namespace에
`scalex-` 접두사를 사용한다. repository 이름 자체는 다를 수 있다.

## 2. child chart 작성

`sample-poc/` 예시와 같은 최소 구조를 만든다.

```text
chart/Chart.yaml
chart/values.yaml
chart/values.schema.json
chart/templates/_helpers.tpl
chart/templates/deployment.yaml
chart/templates/propagation-policy.yaml
scripts/validate.sh
.github/workflows/validate.yaml
```

기능이 필요할 때만 source, Dockerfile, Service, RBAC, `OverridePolicy`를 추가한다. chart는
Namespace나 infra Secret을 생성하지 않는다.

## 3. child를 독립 검증하고 publish

```bash
./scripts/validate.sh
git add .
git commit -m "Add ScaleX child chart"
git push origin main
git rev-parse HEAD
```

마지막 명령의 40자리 SHA와 workload image digest를 기록한다. Federation에 branch나
mutable image tag만 전달하지 않는다.

## 4. Federation source 허용

`scalex-federation/bootstrap/appproject.yaml`의 `spec.sourceRepos`에 정확한 URL을 추가한다.

```yaml
spec:
  sourceRepos:
    - https://github.com/<owner>/sample-poc.git
```

private repository라면 Argo repository credential 준비는 별도 운영 절차다. credential을
child나 Federation Git에 넣지 않는다.

## 5. disabled release 등록

`scalex-federation/releases/scalex-sample-poc/`에 두 파일을 만든다.

```yaml
# releases/scalex-sample-poc/release.yaml
schemaVersion: v1
name: scalex-sample-poc
namespace: scalex-sample-poc
state: disabled
disabledReason: Waiting for chart and member dependency verification.
renderer: helm/v1
source:
  repoURL: https://github.com/<owner>/sample-poc.git
  path: chart
  revision: <40-character-child-commit-sha>
values:
  path: releases/scalex-sample-poc/values.yaml
promotion:
  mode: pinned
```

```yaml
# releases/scalex-sample-poc/values.yaml
image:
  repository: registry.k8s.io/pause
  tag: "3.10"
  digest: sha256:ee6521f290b2168b6e0935a181d4cff9be1ac3f505666ef0e3c98fae8199917a
  pullPolicy: IfNotPresent
karmada:
  enabled: true
  placement:
    cluster: <registered-member-name>
```

`values.yaml`에는 배포마다 달라지는 최소 override만 둔다. sample image는 구조 검증용이며
실제 child는 자신의 검증된 image repository/tag/digest로 교체한다.

## 6. 활성화 전 검증

child repository에서 Federation과 같은 입력으로 렌더링한다.

```bash
helm lint --strict chart \
  --values /path/to/scalex-federation/releases/scalex-sample-poc/values.yaml
helm template scalex-sample-poc chart \
  --namespace scalex-sample-poc \
  --values /path/to/scalex-federation/releases/scalex-sample-poc/values.yaml \
  > /tmp/scalex-sample-poc.yaml
```

다음을 모두 확인한 뒤 별도 Federation PR에서 `state: active`로 바꾼다.

- AppProject에 exact child URL이 있다.
- `source.revision`이 publish한 child의 40자리 SHA다.
- chart path가 실제 `chart/`와 일치한다.
- 렌더 결과의 Deployment image가 digest로 고정된다.
- PropagationPolicy selector가 그 Deployment를 정확히 선택한다.
- 선택한 member 이름이 Tower Karmada에 등록되어 있다.
- member namespace와 필요한 infra dependency가 해당 `*-k8s` 경로로 준비되어 있다.

## 7. 활성화와 rollback

활성화는 Federation PR에서 `state: active`를 merge하는 행위다. Tower Argo의
`scalex-federation` ApplicationSet이 child chart와 Federation values를 함께 읽고 Karmada
destination으로 sync한다. rollback은 `source.revision`과 values를 이전 검증 조합으로
되돌리는 Federation PR로 수행한다.

child CI는 cluster에 직접 apply하거나 `scalex-federation/main`에 직접 push하지 않는다.
