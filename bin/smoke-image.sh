#!/bin/sh
# Local protocol/health smoke test. No host ports, mailbox or persistent volume.
set -eu
image=${1:?Usage: bin/smoke-image.sh IMAGE}
name="jmap-smoke-$$"
cleanup() { docker stop --time 5 "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
docker run -d --rm --name "$name" --network none --tmpfs /data \
  --health-interval 2s --health-start-period 2s --health-timeout 3s --health-retries 15 \
  -e JMAP_SECRET_KEY=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  "$image" >/dev/null
attempt=0
while [ "$attempt" -lt 20 ]; do
  status=$(docker inspect --format '{{.State.Health.Status}}' "$name")
  if [ "$status" = healthy ]; then break; fi
  if [ "$status" = unhealthy ]; then
    docker logs "$name"
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 1
done
test "$status" = healthy
docker exec "$name" perl -MHTTP::Tiny -e '
  my $h = HTTP::Tiny->new(timeout => 3);
  my $health = $h->get("http://127.0.0.1:8080/healthz");
  die "Health endpoint failed" unless $health->{status} == 200;
  my $session = $h->get("http://127.0.0.1:9000/session");
  die "Unauthenticated session did not require authentication" unless $session->{status} == 401;
  print "Health and unauthenticated-session smoke checks passed.\n";
'
