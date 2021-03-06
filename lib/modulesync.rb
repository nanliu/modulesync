require 'fileutils'
require 'pathname'
require 'modulesync/cli'
require 'modulesync/constants'
require 'modulesync/git'
require 'modulesync/hook'
require 'modulesync/renderer'
require 'modulesync/util'

module ModuleSync
  include Constants

  def self.config_defaults
    {
      :project_root         => 'modules/',
      :managed_modules_conf => 'managed_modules.yml',
      :configs              => '.',
      :tag_pattern          => '%s'
    }
  end

  def self.local_file(config_path, file)
    "#{config_path}/#{MODULE_FILES_DIR}/#{file}"
  end

  def self.module_file(project_root, puppet_module, file)
    "#{project_root}/#{puppet_module}/#{file}"
  end

  def self.local_files(path)
    if File.exist?(path)
      local_files = Find.find(path).collect { |file| file unless File.directory?(file) }.compact
    else
      puts "#{path} does not exist. Check that you are working in your module configs directory or that you have passed in the correct directory with -c."
      exit
    end
  end

  def self.module_files(local_files, path)
    local_files.map { |file| file.sub(/#{path}/, '') }
  end

  def self.managed_modules(path, filter)
    managed_modules = Util.parse_config(path)
    if managed_modules.empty?
      puts "No modules found at #{path}. Check that you specified the right configs directory containing managed_modules.yml."
      exit
    end
    managed_modules.select! { |m| m =~ Regexp.new(filter) } unless filter.nil?
    managed_modules
  end

  def self.module_name(module_name, default_namespace)
    return [default_namespace, module_name] unless module_name.include?('/')
    ns, mod = module_name.split('/')
  end

  def self.hook(options)
    hook = Hook.new(HOOK_FILE, options)

    case options[:hook]
    when 'activate'
      hook.activate
    when 'deactivate'
      hook.deactivate
    end
  end

  def self.module_configs(filename, global_defaults, defaults, module_defaults, module_configs)
    global_defaults.merge(defaults[filename] || {}).merge(module_defaults).merge(module_configs[filename] || {})
  end

  def self.unmanaged?(filename, global_defaults, defaults, module_defaults, module_configs)
    Pathname.new(filename).ascend do |v|
      configs = module_configs(v.to_s, global_defaults, defaults, module_defaults, module_configs)
      return true if configs['unmanaged']
    end
    false
  end

  def self.update(options)
    options = config_defaults.merge(options)
    defaults = Util.parse_config("#{options[:configs]}/#{CONF_FILE}")

    path = "#{options[:configs]}/#{MODULE_FILES_DIR}"
    local_files = self.local_files(path)
    module_files = self.module_files(local_files, path)

    managed_modules = self.managed_modules("#{options[:configs]}/managed_modules.yml", options[:filter])

    # managed_modules is either an array or a hash
    managed_modules.each do |puppet_module, opts|
      puts "Syncing #{puppet_module}"
      namespace, module_name = self.module_name(puppet_module, options[:namespace])
      unless options[:offline]
        git_base = options[:git_base]
        git_uri = "#{git_base}#{namespace}"
        Git.pull(git_uri, module_name, options[:branch], options[:project_root], opts || {})
      end
      module_configs = Util.parse_config("#{options[:project_root]}/#{module_name}/#{MODULE_CONF_FILE}")
      global_defaults = defaults[GLOBAL_DEFAULTS_KEY] || {}
      module_defaults = module_configs[GLOBAL_DEFAULTS_KEY] || {}
      files_to_manage = (module_files | defaults.keys | module_configs.keys) - [GLOBAL_DEFAULTS_KEY]
      unmanaged_files = []
      files_to_manage.each do |filename|
        configs = module_configs(filename, global_defaults, defaults, module_defaults, module_configs)
        configs[:puppet_module] = module_name
        configs[:git_base] = git_base
        configs[:namespace] = namespace
        if unmanaged?(filename, global_defaults, defaults, module_defaults, module_configs)
          puts "Not managing #{filename} in #{module_name}"
          unmanaged_files << filename
        elsif configs['delete']
          Renderer.remove(module_file(options['project_root'], module_name, filename))
        else
          templatename = local_file(options[:configs], filename)
          begin
            erb = Renderer.build(templatename)
            template = Renderer.render(erb, configs)
            Renderer.sync(template, "#{options[:project_root]}/#{module_name}/#{filename}")
          rescue
            STDERR.puts "Error while rendering #{filename}"
            raise
          end
        end
      end
      files_to_manage -= unmanaged_files
      if options[:noop]
        Git.update_noop(module_name, options)
      elsif !options[:offline]
        Git.update(module_name, files_to_manage, options)
      end
    end
  end
end
