require 'fourflusher'

PLATFORMS = { 'iphonesimulator' => 'iOS',
              'appletvsimulator' => 'tvOS',
              'watchsimulator' => 'watchOS' }

def build_for_platform(sandbox, build_dir, target, sdks, configuration, enable_bitcode)
  deployment_target = target.platform_deployment_target
  target_label = target.cocoapods_target_label
  spec_names = target.specs.map { |spec| [spec.root.name, spec.root.module_name] }.uniq

  all_modules_csv = spec_names.map { |x, module_name| module_name }.join(", ")

  Pod::UI.puts "[*] #{target_label}"
  Pod::UI.puts "Pods: #{all_modules_csv}"
  Pod::UI.puts ""

  sdks.each do |sdk|
    Pod::UI.puts "  - Building for #{target.platform_name} platform and #{sdk} sdk"
    xcodebuild(sandbox, target_label, sdk, deployment_target, configuration, enable_bitcode)

    spec_names.each do |root_name, module_name|
      pod_build_dir = "#{build_dir}/#{configuration}-#{sdk}/#{root_name}"
      src = "#{pod_build_dir}/#{module_name}.framework"
      dest = "#{build_dir}/#{configuration}-#{sdk}/#{module_name}.framework"

      next unless File.directory?(src)

      FileUtils.cp_r src, dest, :remove_destination => true
      FileUtils.remove_dir pod_build_dir
    end
  end

  Pod::UI.puts ""
end

def xcodebuild(sandbox, target, sdk='macosx', deployment_target=nil, configuration, enable_bitcode)
  args = %W(-project #{sandbox.project_path.realdirpath} -scheme #{target} -configuration #{configuration})

  if sdk == "maccatalyst"
    args += ['-destination', "platform=macOS,arch=x86_64,variant=Mac Catalyst"]
    args += ["CODE_SIGN_IDENTITY=-"]
  else
    args += %W(-sdk #{sdk})

    platform = PLATFORMS[sdk]
    args += Fourflusher::SimControl.new.destination(:oldest, platform, deployment_target) unless platform.nil?
  end

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

  if user_options["pre_compile"]
    user_options["pre_compile"].call(installer_context)
  end

  sandbox_root = Pathname(installer_context.sandbox_root)
  sandbox = Pod::Sandbox.new(sandbox_root)

  enable_debug_information(sandbox.project_path, configuration) if enable_dsym

  build_dir = sandbox_root.parent + 'build'
  destination = sandbox_root.parent + 'Rome'

  Pod::UI.puts 'Building frameworks'

  build_dir.rmtree if build_dir.directory?
  targets = installer_context.umbrella_targets.select { |t| t.specs.any? }
  targets.each do |target|
    sdks = []

    case target.platform_name
    when :ios then sdks = [(build_ios_catalyst ? 'maccatalyst' : nil), 'iphoneos', 'iphonesimulator'].compact
    when :osx then sdks = ['macosx']
    when :tvos then sdks = ['appletvos', 'appletvsimulator']
    when :watchos then sdks = ['watchos', 'watchsimulator']
    else raise "Unknown platform '#{target.platform_name}'" end

    build_for_platform(sandbox, build_dir, target, sdks, configuration, enable_bitcode)
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

  build_dir.rmtree if build_dir.directory?

  if user_options["post_compile"]
    user_options["post_compile"].call(installer_context)
  end
end
