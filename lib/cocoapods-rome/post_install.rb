require 'fourflusher'

PLATFORMS = { 'iphonesimulator' => 'iOS',
              'appletvsimulator' => 'tvOS',
              'watchsimulator' => 'watchOS' }

DESTINATIONS = {
  ios: [
    {
      sdk: :maccatalyst,
      dest: "generic/platform=macOS,variant=Mac Catalyst"
    },
    {
      sdk: :iphonesimulator,
      dest: "generic/platform=iOS Simulator"
    },
    {
      sdk: :iphoneos,
      dest: "generic/platform=iOS"
    }
  ],
  osx: [],
  tvos: [],
  watchos: []
}

def merge_frameworks(build_dir, target, sdks, configuration)
  target_label = target.cocoapods_target_label
  spec_names = target.specs.map { |spec| [spec.root.name, spec.root.module_name] }.uniq
  all_modules_csv = spec_names.map { |x, module_name| module_name }.join(", ")

  Pod::UI.puts "[*] #{target_label}"
  Pod::UI.puts "Pods: #{all_modules_csv}"
  Pod::UI.puts ""

  sdks.each do |sdk|
    Pod::UI.puts "  - Copying #{target.platform_name} platform and #{sdk} sdk"

    spec_names.each do |root_name, module_name|
      pod_build_dir = "#{build_dir}/#{configuration}-#{sdk}/#{root_name}"
      src = "#{pod_build_dir}/#{module_name}.framework"
      dest = "#{build_dir}/#{configuration}-#{sdk}/#{module_name}.framework"

      next unless File.directory?(src)

      FileUtils.cp_r src, dest, :remove_destination => true
    end
  end

  Pod::UI.puts ""
end

def xcodebuild_all_targets_by_destination(sandbox, target, configuration, enable_bitcode, sdk, destination)
  args = %W(-project #{sandbox.project_path.realdirpath} -scheme #{target.cocoapods_target_label} -configuration #{configuration})
  args += ['-destination', destination]
  args << "BITCODE_GENERATION_MODE=bitcode" if enable_bitcode
  Pod::Executable.execute_command 'xcodebuild', args, true
end

def enable_debug_information(project_path, configuration)
  project = Xcodeproj::Project.open(project_path)
  project.targets.each do |target|
    config = target.build_configurations.find { |config| config.name.eql? configuration }
    config.build_settings['DEBUG_INFORMATION_FORMAT'] = 'dwarf-with-dsym'
    config.build_settings['ONLY_ACTIVE_ARCH'] = 'NO'
  end
  project.save
end

def copy_dsym_files(dsym_destination, configuration)
  dsym_destination.rmtree if dsym_destination.directory?
  platforms = ['iphoneos', 'iphonesimulator']
  platforms.each do |platform|
    dsym = Pathname.glob("build/#{configuration}-#{platform}/**/*.dSYM")
    dsym.each do |dsym|
      destination = dsym_destination + platform
      FileUtils.mkdir_p destination
      FileUtils.cp_r dsym, destination, :remove_destination => true
    end
  end
end

Pod::HooksManager.register('cocoapods-rome', :post_install) do |installer_context, user_options|
  enable_dsym = user_options.fetch('dsym', true)
  configuration = user_options.fetch('configuration', 'Debug')
  enable_bitcode = user_options.fetch('enable_bitcode', false)
  build_ios_catalyst = user_options.fetch('build_ios_catalyst', false)
  skipping_umbrella_targets_for_catalyst = user_options.fetch('skipping_umbrella_targets_for_catalyst', [])

  if user_options["pre_compile"]
    user_options["pre_compile"].call(installer_context)
  end

  sandbox_root = Pathname(installer_context.sandbox_root)
  sandbox = Pod::Sandbox.new(sandbox_root)

  enable_debug_information(sandbox.project_path, configuration) if enable_dsym

  build_dir = sandbox_root.parent + 'build'
  rome_dir = sandbox_root.parent + 'Rome'

  Pod::UI.puts 'Building frameworks'

  platforms = installer_context.umbrella_targets.map { |t| t.platform_name }.uniq

  platforms.each do |platform|
    dests = DESTINATIONS[platform] || []
    dests = dests.reject { |d| d[:sdk] == :maccatalyst } unless build_ios_catalyst

    raise "Platform '#{target.platform_name}' has no destination configured in Rome" if dests.empty?

    dests.each do |dest|
      skip_targets = dest[:sdk] == :maccatalyst ? skipping_umbrella_targets_for_catalyst : []
      umbrella_targets = installer_context.umbrella_targets
        .select { |t| t.specs.any? && t.platform_name == platform && !skip_targets.include?(t.cocoapods_target_label) }

      umbrella_targets.each do |target|
        Pod::UI.puts "[*] Building #{target.cocoapods_target_label} for sdk #{dest[:sdk]} and destination #{dest[:dest]}"
        xcodebuild_all_targets_by_destination(sandbox, target, configuration, enable_bitcode, dest[:sdk], dest[:dest])
      end
    end
  end

  raise Pod::Informative, 'The build directory was not found in the expected location.' unless build_dir.directory?

  rome_dir.rmtree if rome_dir.directory?
  FileUtils.mkdir_p rome_dir

  Pod::UI.puts "Creating XCFrameworks from built products in `/#{rome_dir.relative_path_from Pathname.pwd}`"


  built_targets = installer_context.umbrella_targets
    .map { |umbrella|
      umbrella.specs
        .map { |spec| spec.root }
        .map { |rootSpec| { platform: umbrella.platform_name, pod_name: rootSpec.name, module_name: rootSpec.module_name } }
    }
    .flatten
    .uniq
  
  built_targets.each do |spec|
    dests = DESTINATIONS[spec[:platform]] || []
    dests = dests.reject { |d| d[:sdk] == :maccatalyst } unless build_ios_catalyst

    pod_name = spec[:pod_name]
    module_name = spec[:module_name]
    framework_products = dests.map { |d| "#{configuration}-#{d[:sdk]}/#{pod_name}/#{module_name}.framework" }
    output_name = "#{module_name}.xcframework"

    nonexist_variants = framework_products.filter { |path| not Pathname.new("#{build_dir}/#{path}").directory? }

    if !nonexist_variants.empty?
      Pod::UI.puts "[*] Skipping XCFramework creation for #{module_name}"
      nonexist_variants.each do |path|
        Pod::UI.puts "    - because it has no built product at #{path}"
      end
      Pod::UI.puts "    - It could be a Pod with only vendored frameworks."
    else
      Pod::UI.puts "[*] Creating XCFramework for #{module_name}"
      framework_products.each do |path|
        Pod::UI.puts "    - Variant: #{path}"
      end
  
      args = %W(-create-xcframework -allow-internal-distribution -output #{rome_dir}/#{output_name})
      framework_products.each do |path|
        args += %W(-framework #{build_dir}/#{path})
      end
  
      Pod::Executable.execute_command 'xcodebuild', args, true
    end
  end

  Pod::UI.puts "Copying resources and vendored products to `/#{rome_dir.relative_path_from Pathname.pwd}`"

  resources = []
  copy_frameworks = []

  installer_context.umbrella_targets.each do |umbrella|
    umbrella.specs.each do |spec|
      consumer = spec.consumer(umbrella.platform_name)
      file_accessor = Pod::Sandbox::FileAccessor.new(sandbox.pod_dir(spec.root.name), consumer)
      copy_frameworks += file_accessor.vendored_libraries
      copy_frameworks += file_accessor.vendored_frameworks
      resources += file_accessor.resources
    end
  end

  copy_frameworks.uniq!
  resources.uniq!
  
  (resources + copy_frameworks).each do |file|
    FileUtils.cp_r file, rome_dir, :remove_destination => true
  end

  # copy_dsym_files(sandbox_root.parent + 'dSYM', configuration) if enable_dsym

  if user_options["post_compile"]
    user_options["post_compile"].call(installer_context)
  end
end
