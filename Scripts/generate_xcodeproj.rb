#!/usr/bin/env ruby

# Regenerates FlowPeek.xcodeproj from the on-disk layout so the shipping app cannot
# diverge from what SPM compiles. Everything is discovered recursively and sorted, and
# UUIDs are derived from the object graph, so two runs produce a byte-identical
# project.pbxproj -- for one gem version.
#
# `predictabilize_uuids` derives different identifiers across xcodeproj releases, so the version is
# activated explicitly rather than left to whichever copy Rubygems happens to pick. Without this a
# machine with two versions installed silently regenerates every UUID, and the release workflow
# rejects a project that is otherwise identical.
XCODEPROJ_VERSION = "1.28.1"
begin
  gem "xcodeproj", XCODEPROJ_VERSION
rescue Gem::LoadError
  abort <<~MESSAGE
    xcodeproj #{XCODEPROJ_VERSION} is required to generate a project that matches the one in git.
    Install it with:

      gem install xcodeproj -v #{XCODEPROJ_VERSION}
  MESSAGE
end

require "xcodeproj"

DEPLOYMENT_TARGET = "14.0"
SWIFT_VERSION = "6.0"
DEVELOPMENT_TEAM = "F7WUT95TT6"
# Defaults for a local build. The release workflow overrides both from the pushed tag.
MARKETING_VERSION = "0.1.0"
CURRENT_PROJECT_VERSION = "1"
BUNDLE_ID = "com.selenehyun.FlowPeek"
# Carried by SPM's `.process("Resources")` rule, not by the app bundle.
EXCLUDED_RESOURCES = ["placeholder.txt", ".DS_Store"].freeze

root = File.expand_path("..", __dir__)
project_path = File.join(root, "FlowPeek.xcodeproj")

# Every path relative to `directory`, recursive, sorted, matching `pattern`.
def relative_files(directory, pattern)
  Dir.glob(File.join(directory, "**", pattern), File::FNM_DOTMATCH)
    .select { |path| File.file?(path) }
    .map { |path| path.sub("#{directory}/", "") }
    .sort
end

# Mirrors a relative directory into nested PBXGroups under `base`, memoised so the same
# directory is never created twice.
def group_for(base, cache, relative_directory)
  return base if relative_directory == "."

  cache[relative_directory] ||= begin
    parent = group_for(base, cache, File.dirname(relative_directory))
    name = File.basename(relative_directory)
    parent.new_group(name, name)
  end
end

def add_swift_sources(root, directory, group, target, excluding: [])
  cache = {}
  relative_files(File.join(root, directory), "*.swift").each do |relative|
    next if excluding.any? { |prefix| relative.start_with?("#{prefix}/") }

    reference = group_for(group, cache, File.dirname(relative)).new_file(File.basename(relative))
    target.source_build_phase.add_file_reference(reference)
  end
end

project = Xcodeproj::Project.new(project_path)
project.root_object.development_region = "en"

sources = project.main_group.new_group("Sources", "Sources")
core_group = sources.new_group("FlowPeekCore", "FlowPeekCore")
app_group = sources.new_group("FlowPeek", "FlowPeek")
tests_group = project.main_group.new_group("Tests", "Tests")
config_group = project.main_group.new_group("Config", "Config")

core = project.new_target(:static_library, "FlowPeekCore", :osx, DEPLOYMENT_TARGET)
app = project.new_target(:application, "FlowPeek", :osx, DEPLOYMENT_TARGET)
app.add_dependency(core)
app.frameworks_build_phase.add_file_reference(core.product_reference)

add_swift_sources(root, "Sources/FlowPeekCore", core_group, core)
add_swift_sources(root, "Sources/FlowPeek", app_group, app, excluding: ["Resources"])

# Every non-Swift file under Resources ships, so adding one cannot be forgotten here.
# .lproj files are wired separately, as variant groups.
resources_root = File.join(root, "Sources/FlowPeek/Resources")
resources_group = app_group.new_group("Resources", "Resources")
resources_cache = {}
relative_files(resources_root, "*").each do |relative|
  next if relative.end_with?(".swift")
  next if relative.split("/").any? { |component| component.end_with?(".lproj") }
  next if EXCLUDED_RESOURCES.include?(File.basename(relative))

  reference = group_for(resources_group, resources_cache, File.dirname(relative)).new_file(File.basename(relative))
  app.resources_build_phase.add_file_reference(reference)
end

# The Icon Composer document. actool compiles `.icon` directly -- it is not an asset catalogue and
# must not be walked into, so it is added as a single file reference at the project root.
icon_document = File.join(root, "AppIcon.icon")
if File.directory?(icon_document)
  app.resources_build_phase.add_file_reference(project.main_group.new_file("AppIcon.icon"))
end

localizations = Dir.glob(File.join(resources_root, "*.lproj")).map { |path| File.basename(path, ".lproj") }.sort
variants = localizations.flat_map { |language| Dir.glob(File.join(resources_root, "#{language}.lproj", "*")) }
                        .map { |path| File.basename(path) }.uniq.sort
variants.each do |name|
  variant = resources_group.new_variant_group(name)
  localizations.each do |language|
    next unless File.exist?(File.join(resources_root, "#{language}.lproj", name))

    variant.new_file("#{language}.lproj/#{name}")
  end
  app.resources_build_phase.add_file_reference(variant)
end
project.root_object.known_regions = localizations + ["Base"]

config_group.new_file("Info.plist")
config_group.new_file("FlowPeek.entitlements")

package = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
package.repositoryURL = "https://github.com/sparkle-project/Sparkle"
package.requirement = { "kind" => "exactVersion", "version" => "2.9.2" }
project.root_object.package_references << package
product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
product.package = package
product.product_name = "Sparkle"
app.package_product_dependencies << product
build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
build_file.product_ref = product
app.frameworks_build_phase.files << build_file

# FlowPeekCoreTests is pure logic and links the static library directly.
# FlowPeekRendererTests drives AppKit + WebKit and must be hosted by the app so
# Bundle.main resolves to the real .app and mermaid.min.js is where the renderer
# expects it.
core_tests = project.new_target(:unit_test_bundle, "FlowPeekCoreTests", :osx, DEPLOYMENT_TARGET)
core_tests.add_dependency(core)
core_tests.frameworks_build_phase.add_file_reference(core.product_reference)
core_tests_group = tests_group.new_group("FlowPeekCoreTests", "FlowPeekCoreTests")
add_swift_sources(root, "Tests/FlowPeekCoreTests", core_tests_group, core_tests)

renderer_tests = project.new_target(:unit_test_bundle, "FlowPeekRendererTests", :osx, DEPLOYMENT_TARGET)
renderer_tests.add_dependency(app)
renderer_tests_group = tests_group.new_group("FlowPeekRendererTests", "FlowPeekRendererTests")
add_swift_sources(root, "Tests/FlowPeekRendererTests", renderer_tests_group, renderer_tests)

project.build_configurations.each do |configuration|
  configuration.build_settings["MACOSX_DEPLOYMENT_TARGET"] = DEPLOYMENT_TARGET
end

core.build_configurations.each do |configuration|
  configuration.build_settings.merge!({
    "PRODUCT_MODULE_NAME" => "FlowPeekCore",
    "PRODUCT_NAME" => "FlowPeekCore",
    "SWIFT_VERSION" => SWIFT_VERSION,
    "SKIP_INSTALL" => "YES",
    "ENABLE_TESTABILITY" => configuration.name == "Debug" ? "YES" : "NO",
  })
end

app.build_configurations.each do |configuration|
  configuration.build_settings.merge!({
    "PRODUCT_BUNDLE_IDENTIFIER" => BUNDLE_ID,
    "PRODUCT_NAME" => "FlowPeek",
    "INFOPLIST_FILE" => "Config/Info.plist",
    "GENERATE_INFOPLIST_FILE" => "NO",
    "CODE_SIGN_ENTITLEMENTS" => "Config/FlowPeek.entitlements",
    "CODE_SIGN_STYLE" => "Automatic",
    "DEVELOPMENT_TEAM" => DEVELOPMENT_TEAM,
    "ENABLE_APP_SANDBOX" => "NO",
    "MARKETING_VERSION" => MARKETING_VERSION,
    "CURRENT_PROJECT_VERSION" => CURRENT_PROJECT_VERSION,
    # The hosted test bundle is a second signature loaded into the app, which library
    # validation under the hardened runtime refuses. Release keeps it on.
    "ENABLE_HARDENED_RUNTIME" => configuration.name == "Debug" ? "NO" : "YES",
    "ENABLE_TESTABILITY" => configuration.name == "Debug" ? "YES" : "NO",
    "SWIFT_VERSION" => SWIFT_VERSION,
    "SWIFT_EMIT_LOC_STRINGS" => "YES",
    "LD_RUNPATH_SEARCH_PATHS" => "$(inherited) @executable_path/../Frameworks",
  })
end

[core_tests, renderer_tests].each do |target|
  target.build_configurations.each do |configuration|
    configuration.build_settings.merge!({
      "PRODUCT_BUNDLE_IDENTIFIER" => "#{BUNDLE_ID}.#{target.name}",
      "PRODUCT_NAME" => "$(TARGET_NAME)",
      "GENERATE_INFOPLIST_FILE" => "YES",
      "CODE_SIGN_STYLE" => "Automatic",
      "DEVELOPMENT_TEAM" => DEVELOPMENT_TEAM,
      "SWIFT_VERSION" => SWIFT_VERSION,
      "SKIP_INSTALL" => "YES",
      "LD_RUNPATH_SEARCH_PATHS" => "$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks",
    })
  end
end

renderer_tests.build_configurations.each do |configuration|
  configuration.build_settings.merge!({
    "TEST_HOST" => "$(BUILT_PRODUCTS_DIR)/FlowPeek.app/Contents/MacOS/FlowPeek",
    "BUNDLE_LOADER" => "$(TEST_HOST)",
  })
end

project.root_object.attributes["TargetAttributes"] = {
  renderer_tests.uuid => { "TestTargetID" => app.uuid },
}

# MD5-of-object-graph UUIDs: without this every run rewrites project.pbxproj with fresh
# random ids and the "regenerate and diff" CI check can never pass. Twice, because a
# PBXTargetDependency hashes its remoteGlobalIDString, which is still a random UUID
# during the first pass and only becomes stable once that pass has rewritten it.
2.times { project.predictabilize_uuids }
project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(core_tests)
scheme.add_test_target(renderer_tests)
scheme.set_launch_target(app)
scheme.save_as(project_path, "FlowPeek", true)

puts "Generated #{project_path}"
