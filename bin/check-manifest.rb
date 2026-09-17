#!/usr/bin/env ruby
# frozen_string_literal: true

# Applies contract 6.2 and 6.3 to the manifest **as published**, rather than to
# a second transcription of the same key set.
#
#   ruby check-manifest.rb <bundle-dir>
#
# The handoff's shell implements these assertions against $SDK, $SRC,
# $WASI_VFS and friends, which are a copy of the key set that never ships. A
# wrong value in manifest.yml passes every one of them. This reads the file the
# bundle carries and nothing else.

require "yaml"

dir = ARGV[0] or abort "usage: #{File.basename($PROGRAM_NAME)} <bundle-dir>"
manifest = YAML.safe_load_file(File.join(dir, "manifest.yml"))
trace =
  %w[link.paths.txt compile.paths.txt].flat_map do |name|
    File.readlines(File.join(dir, name), chomp: true)
  end
keys = manifest.fetch("path_keys")
stops = []

# 5.4 — tokens first, then roots as prefixes of what remains.
tokens = keys.select { |_, k| k["kind"] == "token" }
roots = keys.select { |_, k| k["kind"] == "root" }

covering = lambda do |path|
  name, = tokens.find { |_, k| k["value"] == path }
  return name if name
  # 5.3 — a root matches a leading prefix, and a value is a prefix of itself.
  name, = roots.find { |_, k| path == k["value"] || path.start_with?(k["value"] + "/") }
  name
end

# 6.2 — every absolute embedded path starts with a declared key.
matched = Hash.new(0)
trace.each do |path|
  name = covering.call(path)
  if name.nil?
    stops << "6.2 uncovered: #{path}"
  else
    matched[name] += 1
  end
end

# 6.3 — every declared key matches at least once, no exemptions.
keys.each_key do |name|
  stops << "6.3 key matches nothing: #{name} = #{keys[name]['value']}" if matched[name].zero?
end

# 6.2 — non-ambiguity.
roots.each do |a, ka|
  roots.each do |b, kb|
    next if a == b
    stops << "6.2 root #{a} is a prefix of root #{b}" if kb["value"].start_with?(ka["value"] + "/")
  end
end
tokens.to_a.combination(2) do |(a, ka), (b, kb)|
  stops << "6.2 tokens #{a} and #{b} share a value" if ka["value"] == kb["value"]
end
tokens.each do |t, kt|
  roots.each { |r, kr| stops << "6.2 token #{t} equals root #{r}" if kt["value"] == kr["value"] }
end

# 6.4 — no path on the link recipe carries an unaccounted key.
File.readlines(File.join(dir, "link.paths.txt"), chomp: true).each do |path|
  name = covering.call(path)
  next if name.nil? || !keys[name]["accounted"].nil?
  stops << "6.4 link recipe carries unaccounted key #{name}: #{path}"
end

# 6.2 — every accounted reference resolves. A member reference resolves against
# hashes.txt, which does not exist until the tree is assembled, so this is the
# one bullet that has to run twice: once now for the tools references, and
# again after 6.6 for the member ones. Skipping it silently is what the
# contract says an assertion must not do, so it says which half it ran.
hashes = File.join(dir, "hashes.txt")
listed = File.exist?(hashes) ? File.readlines(hashes, chomp: true).map { |l| l.split("  ", 2)[1] } : nil
deferred = []
keys.each do |name, k|
  ref = k["accounted"]
  next if ref.nil?
  if ref.start_with?("tools.")
    field = ref.delete_prefix("tools.")
    stops << "6.2 #{name}: no tools.#{field} in the manifest" unless manifest["tools"].key?(field)
  elsif listed.nil?
    deferred << "#{name} -> #{ref}"
  elsif !listed.include?(ref)
    stops << "6.2 #{name}: accounted member #{ref} is not in hashes.txt"
  end
end

matched.each { |name, n| puts format("  %-14s %d", name, n) }

unless deferred.empty?
  puts "  deferred until hashes.txt exists: #{deferred.join(', ')}"
end

if stops.empty?
  puts "manifest agrees with the traces it ships beside"
else
  stops.each { |s| warn "STOP #{s}" }
  exit 1
end