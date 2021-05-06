require 'fourflusher'

PLATFORMS = { 'iphonesimulator' => 'iOS',
              'appletvsimulator' => 'tvOS',
              'watchsimulator' => 'watchOS' }

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

def xcodebuild_all_targets(sandbox, umbrella_targets, configuration, enable_bitcode, sdk, run_in_x86_64)
  if sdk == "maccatalyst"
    # Mac Catalyst cannot be built using `-alltargets`. So we have to fallback to
    # build scheme by scheme.
    xcodebuild_all_targets_catalyst(sandbox, umbrella_targets, configuration, enable_bitcode, sdk, run_in_x86_64)
    return
  end

  args = %W(-project #{sandbox.project_path.realdirpath} -alltargets -configuration #{configuration})
  args += %W(-sdk #{sdk})
  args << "BITCODE_GENERATION_MODE=bitcode" if enable_bitcode

  xcodebuild(args, run_in_x86_64)
end

def xcodebuild_all_targets_catalyst(sandbox, umbrella_targets, configuration, enable_bitcode, sdk, run_in_x86_64)
  umbrella_targets.each do |target|
    args = %W(-project #{sandbox.project_path.realdirpath} -scheme #{target.cocoapods_target_label} -configuration #{configuration})
    args += ['-destination', "platform=macOS,arch=x86_64,variant=Mac Catalyst"]
    args << "BITCODE_GENERATION_MODE=bitcode" if enable_bitcode
    xcodebuild(args, run_in_x86_64)
  end
end

def xcodebuild(args, run_in_x86_64)
  if run_in_x86_64
    Pod::Executable.execute_command 'arch', %W(-x86_64 xcodebuild) + args, true
  else
    Pod::Executable.execute_command 'xcodebuild', args, true
  end
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
  run_in_x86_64 = user_options.fetch('run_in_x86_64', false)
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
  destination = sandbox_root.parent + 'Rome'

  Pod::UI.puts 'Building frameworks'

  platforms = installer_context.umbrella_targets.map { |t| t.platform_name }.uniq

  platforms.each do |platform|
    sdks = []

    case platform
    when :ios then sdks = [(build_ios_catalyst ? 'maccatalyst' : nil), 'iphoneos', 'iphonesimulator'].compact
    when :osx then sdks = ['macosx']
    when :tvos then sdks = ['appletvos', 'appletvsimulator']
    when :watchos then sdks = ['watchos', 'watchsimulator']
    else raise "Unknown platform '#{target.platform_name}'" end

    sdks.each do |sdk|  
      skip_targets = sdk == "maccatalyst" ? skipping_umbrella_targets_for_catalyst : []
      umbrella_targets = installer_context.umbrella_targets
        .select { |t| t.specs.any? && t.platform_name == platform && !skip_targets.include?(t.cocoapods_target_label) }

      Pod::UI.puts "[*] Building all Pods for #{sdk} sdk"
      xcodebuild_all_targets(sandbox, umbrella_targets, configuration, enable_bitcode, sdk, run_in_x86_64)

      umbrella_targets.each do |target|
          merge_frameworks(build_dir, target, sdks, configuration)
      end
    end
  end

  raise Pod::Informative, 'The build directory was not found in the expected location.' unless build_dir.directory?

  # Make sure the device target overwrites anything in the simulator build, otherwise iTunesConnect
  # can get upset about Info.plist containing references to the simulator SDK
  built_products = Pathname.glob("build/#{configuration}-*")

  resources = []
  copy_frameworks = []

  destination.rmtree if destination.directory?

  installer_context.umbrella_targets.each do |umbrella|
    umbrella.specs.each do |spec|
      consumer = spec.consumer(umbrella.platform_name)
      file_accessor = Pod::Sandbox::FileAccessor.new(sandbox.pod_dir(spec.root.name), consumer)
      copy_frameworks += file_accessor.vendored_libraries
      copy_frameworks += file_accessor.vendored_frameworks
      resources += file_accessor.resources
    end
  end

  built_products.uniq!
  copy_frameworks.uniq!
  resources.uniq!

  Pod::UI.puts "Copying built products, resources and vendored products to `#{destination.relative_path_from Pathname.pwd}`"

  FileUtils.mkdir_p destination
  
  (resources + copy_frameworks + built_products).each do |file|
    FileUtils.cp_r file, destination, :remove_destination => true
  end

  copy_dsym_files(sandbox_root.parent + 'dSYM', configuration) if enable_dsym

  if user_options["post_compile"]
    user_options["post_compile"].call(installer_context)
  end
end
