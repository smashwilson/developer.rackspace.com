#!/usr/bin/env ruby

require 'erb'
require 'fileutils'
require 'json'

Language = Struct.new(:name, :syntax, :ext, :build, :executable)

# Collected knowledge about supported programming languages.
#
LANGUAGES = [
  Language.new('C#', 'csharp', 'cs', 'gcs', 'mono'),
  Language.new('Java', 'java', 'java', 'javac', 'java'),
  Language.new('JavaScript', 'javascript', 'js', nil, 'node'),
  Language.new('PHP', 'php', 'php', nil, 'php'),
  Language.new('Python', 'python', 'py', nil, 'python'),
  Language.new('Ruby', 'ruby', 'rb', nil, 'ruby'),
]

ROOT = File.join __dir__, '..'

# Data structure to capture output and progress.
#
Outcome = Struct.new(:service, :language, :output, :kind)

# Exceptions to catch.

class MissingError < RuntimeError ; end

# Enumerate the services that are documented.
#
def services
  entries = Dir[File.join ROOT, 'docs', '*']
  entries = entries.select { |e| File.directory? e }
  entries = entries.map { |e| File.basename e }
  entries = entries.reject { |e| e =~ /^_/ }
  entries
end

# Load an arbitrary set of credentials from a .json file in this directory. See
# `credentials.json.example` for the expected keys.
#
def credentials
  credentials_path = File.join __dir__, 'credentials.json'

  unless File.exists? credentials_path
    $stderr.puts "You don't have a credentials file!"
    $stderr.puts "cp #{credentials_path}.example #{credentials_path}"
    raise RuntimeError.new('Missing credentials')
  end

  JSON.load(File.read credentials_path)
end

# Assemble the code samples for a specific language, within a certain service,
# into a single file, ready to be built (if necessary) and executed. Return the
# path of the templated file.
#
def assemble(credentials, service, language)
  FileUtils.mkdir_p File.join(__dir__, 'assembled')

  # Initialize state that's used by #inject.
  @service, @language = service, language

  b = binding
  @template_path = File.join __dir__, 'templates', "#{@service}.#{@language.ext}.erb"

  unless File.exist? @template_path
    $stderr.puts "Missing template for #{@service} and #{@language.name}."
    $stderr.puts "Expected path: #{@template_path}"
    raise MissingError.new
  end

  template = File.read(@template_path)
  out_path = File.join(__dir__, 'assembled', "#{@service}.#{@language.ext}")

  ERB.new(template, 0, "", "@output").result b
  File.write(out_path, @output)
  out_path
end

# Execute the named file with the interpreter associated with it. Create and
# return an Outcome object.
#
def execute(service, language, path)
  outcome = Outcome.new(service, language)

  IO.popen([language.executable, path], err: [:child, :out]) do |io|
    outcome.output = io.read
  end
  outcome.kind = ($?.success? ? :success : :failure)

  outcome
end

## Template utilities

# These methods are intended to be used within .erb templates in the templates/
# directory. They will inherit this file's scope, though.

# Inject the contents of a specific code sample from the current service
# documentation.
def inject(name)
  sample_root = File.join(__dir__, '..', 'docs', @service, 'samples')
  sample_path = File.join(sample_root, "#{name.to_s}.rst")

  unless File.exists?(sample_path)
    $stderr.puts "The template #{@template_file} references a missing code sample."
    $stderr.puts "  Sample name: #{name} path: #{sample_path}"
    return ''
  end

  relevant_lines = []
  in_section, indent = false, nil

  File.readlines(sample_path).each do |line|
    if line =~ /^.. code-block:: #{@language.syntax}$/
      in_section = true
    elsif line =~ /^.. code-block::.*$/
      in_section = false
    elsif in_section
      indent = line.index /\S/ if indent.nil?
      relevant_lines << (indent.nil? ? line : line[indent..-1])
    end
  end

  if relevant_lines.empty?
    $stderr.puts "The #{@service} sample for #{name} is missing a code block for #{@language.ext}."
    return ''
  end

  relevant_section = relevant_lines.join

  # Inject credentials into the rendered code.
  credentials.each { |key, value| relevant_section.gsub!("{#{key}}", value) }

  relevant_section
end

## All together now.

@credentials = credentials
@outcomes = []

services.each do |service|
  LANGUAGES.each do |language|
    puts ">> #{service} in #{language.name} ..."

    begin
      path = assemble(@credentials, service, language)
      result = execute(service, language, path)
      @outcomes << result
      if result.kind == :success
        puts '<< succeeded'
      else
        puts result.output
        puts '<< failed'
      end
    rescue MissingError => e
      puts '<< missing'

      @outcomes << Outcome.new(service, language, '', :missing)
    end
  end
end

last_service = nil
success_count, failure_count, missing_count = 0, 0, 0
@outcomes.each do |outcome|
  if outcome.service != last_service
    $stdout.flush
    print "\n#{outcome.service.rjust(15)}: "
    last_service = outcome.service
  end

  print "#{outcome.language.name} "
  case outcome.kind
  when :success
    success_count += 1
    print '. '
  when :failure
    failure_count += 1
    print 'x '
  when :missing
    missing_count += 1
    print '? '
  else
    raise RuntimeError.new("Unexpected Outcome kind: #{outcome.kind.inspect}")
  end
end

puts
puts
puts "Total: #{success_count} succeeded / #{failure_count} failed / #{missing_count} missing"
