source 'https://github.com/CocoaPods/Specs.git'

minVersion = '12.0'

platform :osx, minVersion

# cocoapods-prune-localizations doesn't appear to auto-detect pods properly, so using a manual list
supported_locales = ['Base', 'da', 'de', 'en', 'es', 'fr', 'it', 'ja', 'ko', 'nl', 'pt-BR', 'sv', 'tr', 'zh-Hans']
plugin 'cocoapods-prune-localizations', { :localizations => supported_locales }

target "SelfControl" do
    use_frameworks! :linkage => :static
    pod 'MASPreferences', '~> 1.1.4'
    pod 'TransformerKit', :git => 'https://github.com/MacPass/TransformerKit.git', :branch => 'master'
    pod 'FormatterKit/TimeIntervalFormatter', '~> 1.8.0'
    pod 'LetsMove', '~> 1.24'
    pod 'Sentry', '9.14.0'

    # Add test target
    target 'SelfControlTests' do
        inherit! :complete
    end
end

target "SelfControl Killer" do
    use_frameworks! :linkage => :static
    # Sentry removed - incompatible with macOS 26 C++ toolchain
end

# CLI tools don't need Sentry - the main app handles crash reporting
target "SCKillerHelper" do
end
target "selfcontrol-cli" do
end
target "org.eyebeam.selfcontrold" do
end

post_install do |pi|
   pi.pods_project.targets.each do |t|
       t.build_configurations.each do |bc|
           if Gem::Version.new(bc.build_settings['MACOSX_DEPLOYMENT_TARGET']) < Gem::Version.new(minVersion)
               bc.build_settings['MACOSX_DEPLOYMENT_TARGET'] = minVersion
           end
       end
   end

   # Fix TransformerKit Darwin.Availability import issue for modern Xcode
   system("find 'Pods/TransformerKit' -name '*.h' -o -name '*.m' | xargs sed -i '' 's/@import Darwin\\.Availability;/#import <Availability.h>/g' 2>/dev/null || true")
   system("find 'Pods/TransformerKit' -name '*.m' | xargs sed -i '' 's/@import Darwin\\.C\\.time;/#include <time.h>/g' 2>/dev/null || true")
   system("find 'Pods/TransformerKit' -name '*.m' | xargs sed -i '' 's/@import Darwin\\.C\\.xlocale;/#include <xlocale.h>/g' 2>/dev/null || true")
   system("find 'Pods/TransformerKit' -name '*.m' | xargs sed -i '' 's/@import ObjectiveC\\.runtime;/#import <objc\\/runtime.h>/g' 2>/dev/null || true")

   # Fix MASPreferences resource path for macOS frameworks (CocoaPods bug)
   # The generated script looks for .framework/en.lproj but macOS frameworks use .framework/Resources/en.lproj
   Dir["Pods/Target Support Files/**/**-resources.sh"].each do |resource_script|
      text = File.read(resource_script)
      text.gsub!("MASPreferences.framework/en.lproj", "MASPreferences.framework/Resources/en.lproj")
      File.write(resource_script, text)
   end

end
