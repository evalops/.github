# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tempfile"
require "yaml"

class ValidateServicesCatalogTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCRIPT = File.join(ROOT, ".github/scripts/validate-services-catalog.rb")

  def test_current_catalog_is_valid
    stdout, stderr, status = Open3.capture3("ruby", SCRIPT, File.join(ROOT, "services.yaml"))

    assert status.success?, stderr
    assert_match(/ok .*services\.yaml \(71 services\)/, stdout)
  end

  def test_unknown_dependency_fails
    catalog = minimal_catalog
    catalog["services"]["identity"]["depends_on"] = ["missing-service"]

    stdout, stderr, status = run_validator(catalog)

    refute status.success?, stdout
    assert_match(/identity: depends_on references unknown service "missing-service"/, stderr)
  end

  def test_duplicate_repo_fails
    catalog = minimal_catalog
    catalog["services"]["proto"]["repo"] = "evalops/identity"

    stdout, stderr, status = run_validator(catalog)

    refute status.success?, stdout
    assert_match(/proto: repo duplicates identity/, stderr)
  end

  def test_invalid_enum_values_fail
    catalog = minimal_catalog
    catalog["services"]["identity"]["tier"] = "urgent"
    catalog["services"]["identity"]["runtime"] = "laptop"

    stdout, stderr, status = run_validator(catalog)

    refute status.success?, stdout
    assert_match(/identity: tier must be one of critical, standard, experimental/, stderr)
    assert_match(/identity: runtime must be one of gke, none, standalone/, stderr)
  end

  def test_proto_consumer_is_validated_even_when_depends_on_type_is_invalid
    catalog = minimal_catalog
    catalog["services"]["identity"]["depends_on"] = "proto"
    catalog["services"]["identity"]["proto_consumer"] = "yes"

    stdout, stderr, status = run_validator(catalog)

    refute status.success?, stdout
    assert_match(/identity: depends_on must be a list when present/, stderr)
    assert_match(/identity: proto_consumer must be true or false when present/, stderr)
  end

  private

  def run_validator(catalog)
    Tempfile.create(["services", ".yaml"]) do |file|
      file.write(YAML.dump(catalog))
      file.flush
      return Open3.capture3("ruby", SCRIPT, file.path)
    end
  end

  def minimal_catalog
    {
      "services" => {
        "identity" => {
          "description" => "Identity service",
          "team" => "platform-team",
          "language" => "go",
          "tier" => "critical",
          "runtime" => "gke",
          "depends_on" => ["proto"],
          "proto_consumer" => true,
          "repo" => "evalops/identity",
        },
        "proto" => {
          "description" => "Shared protobuf contracts",
          "team" => "api-team",
          "language" => "typescript",
          "tier" => "critical",
          "runtime" => "none",
          "repo" => "evalops/proto",
        },
      },
    }
  end
end
