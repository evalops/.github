#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require "yaml"

ALLOWED_TIERS = %w[critical standard experimental].freeze
ALLOWED_RUNTIMES = %w[gke none standalone].freeze
REQUIRED_FIELDS = %w[description team language tier runtime repo].freeze

options = {
  path: "services.yaml",
}

OptionParser.new do |parser|
  parser.banner = "Usage: validate-services-catalog.rb [services.yaml]"
end.parse!

options[:path] = ARGV.fetch(0, options[:path])

def error(errors, service, message)
  errors << "#{service}: #{message}"
end

catalog = YAML.load_file(options[:path])
services = catalog.fetch("services")
errors = []

unless services.is_a?(Hash) && services.any?
  abort "#{options[:path]}: services must be a non-empty mapping"
end

seen_repos = {}
services.each do |name, service|
  unless name.to_s.match?(/\A[a-z0-9][a-z0-9-]*\z/)
    error(errors, name, "service key must be kebab-safe lowercase")
  end

  unless service.is_a?(Hash)
    error(errors, name, "service entry must be a mapping")
    next
  end

  REQUIRED_FIELDS.each do |field|
    value = service[field]
    error(errors, name, "missing #{field}") if value.nil? || value.to_s.strip.empty?
  end

  description = service["description"].to_s.strip
  error(errors, name, "description must be at least 8 characters") if description.length < 8

  tier = service["tier"].to_s
  error(errors, name, "tier must be one of #{ALLOWED_TIERS.join(", ")}") unless ALLOWED_TIERS.include?(tier)

  runtime = service["runtime"].to_s
  unless ALLOWED_RUNTIMES.include?(runtime)
    error(errors, name, "runtime must be one of #{ALLOWED_RUNTIMES.join(", ")}")
  end

  repo = service["repo"].to_s
  unless repo.match?(/\Aevalops\/[a-z0-9][a-z0-9._-]*\z/)
    error(errors, name, "repo must look like evalops/<repo>")
  end

  if (previous = seen_repos[repo])
    error(errors, name, "repo duplicates #{previous}")
  else
    seen_repos[repo] = name
  end

  depends_on = service.fetch("depends_on", [])
  unless depends_on.is_a?(Array)
    error(errors, name, "depends_on must be a list when present")
  else
    depends_on.each do |dependency|
      unless services.key?(dependency)
        error(errors, name, "depends_on references unknown service #{dependency.inspect}")
      end
    end
  end

  next unless service.key?("proto_consumer")

  proto_consumer = service["proto_consumer"]
  unless proto_consumer == true || proto_consumer == false
    error(errors, name, "proto_consumer must be true or false when present")
  end
end

if errors.any?
  warn "#{options[:path]} failed validation:"
  errors.each { |message| warn "- #{message}" }
  exit 1
end

puts "ok #{options[:path]} (#{services.length} services)"
