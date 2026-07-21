# frozen_string_literal: true

require "rails/generators"
require "generators/gravis/install/install_generator"

RSpec.describe Gravis::Generators::InstallGenerator do
  let(:destination) { Dir.mktmpdir("gravis-generator") }

  after { FileUtils.remove_entry(destination) }

  def run_generator
    output = StringIO.new
    original = $stdout
    $stdout = output
    described_class.start([], destination_root: destination)
    output.string
  ensure
    $stdout = original
  end

  it "creates only the initializer — the worker queue config ships inside the gem" do
    run_generator

    expect(File).to exist(File.join(destination, "config/initializers/gravis.rb"))
    expect(File).not_to exist(File.join(destination, "config/queue_gravis.yml"))
  end

  it "creates the initializer with every option commented out (defaults suffice)" do
    run_generator

    content = File.read(File.join(destination, "config/initializers/gravis.rb"))
    expect(content).to include("Gravis.configure")
    %w[default_cpu default_memory max_concurrent_tasks dispatch_interval idle_grace max_lifetime].each do |option|
      expect(content).to include("# config.#{option}")
    end
  end

  it "prints the remaining manual steps with valid snippets" do
    output = run_generator

    expect(output).to include("include Gravis::Job")
    expect(output).to include("gravis cpu: 8, memory: 16")
    # Regression: the ERB snippet must print as real ERB, not escaped %%.
    expect(output).to include('<%= ENV.fetch("SOLID_QUEUE_QUEUES", "*") %>')
    expect(output).not_to include("<%%")
    expect(output).to include("GRAVIS_TARGET")
    expect(output).not_to include("recurring.yml")
    # Publishable artifact: no private infra constructs named in gem output.
    expect(output).not_to include("GravisTaskRunner")
    expect(output).not_to include("zar")
  end
end
