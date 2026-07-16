#!/usr/bin/env bash
set -euo pipefail

rendered=${1:?rendered manifest path is required}
ruby -ryaml -e '
  documents = File.read(ARGV.fetch(0)).split(/^---\s*$/).filter_map do |source|
    YAML.safe_load(source, permitted_classes: [], permitted_symbols: [], aliases: false)
  end
  expected = {
    "CronJob" => ["temp-poc-batch-analyzer"],
    "Deployment" => ["temp-poc-dataset-ingest", "temp-poc-report-generator"],
    "OverridePolicy" => ["temp-poc-dataset-ingest", "temp-poc-report-generator"],
    "PropagationPolicy" => ["temp-poc-batch-analyzer", "temp-poc-dataset-ingest", "temp-poc-report-generator"],
    "Service" => ["temp-poc-dataset-ingest", "temp-poc-report-generator"]
  }
  expected.each do |kind, names|
    actual = documents.select { |document| document["kind"] == kind }.map { |document| document.dig("metadata", "name") }.sort
    abort "unexpected #{kind} identities" unless actual == names
  end
  policies = documents.select { |document| document["kind"] == "PropagationPolicy" }
  placements = policies.to_h do |policy|
    [policy.dig("metadata", "name"), policy.dig("spec", "placement", "clusterAffinity", "clusterNames")]
  end
  abort "dataset placement mismatch" unless placements["temp-poc-dataset-ingest"] == ["b"]
  abort "analyzer placement mismatch" unless placements["temp-poc-batch-analyzer"] == ["c"]
  abort "report placement mismatch" unless placements["temp-poc-report-generator"] == ["b"]
  services = documents.select { |document| document["kind"] == "Service" }
  abort "base Services must remain ClusterIP" unless services.all? { |service| service.dig("spec", "type") == "ClusterIP" }
  overrides = documents.select { |document| document["kind"] == "OverridePolicy" }
  addresses = overrides.to_h do |policy|
    entries = policy.dig("spec", "overrideRules", 0, "overriders", "plaintext")
    address = entries.find { |entry| entry["path"] == "/metadata/annotations/lbipam.cilium.io~1ips" }
    [policy.dig("metadata", "name"), address["value"]]
  end
  abort "dataset address mismatch" unless addresses["temp-poc-dataset-ingest"] == "10.33.142.20"
  abort "report address mismatch" unless addresses["temp-poc-report-generator"] == "10.33.142.21"
' "$rendered"
