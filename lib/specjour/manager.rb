module Specjour
  class Manager
    require 'dnssd'
    require 'specjour/rspec'
    require 'specjour/cucumber'

    include DRbUndumped
    include SocketHelper

    attr_accessor :project_name, :preload_spec, :preload_feature, :worker_task, :pid
    attr_reader :worker_size, :dispatcher_uri, :registered_projects, :load_pid, :options

    def self.start_quietly(options)
      manager = new options.merge(:quiet => true)
      manager.drb_uri
      manager.pid = QuietFork.fork { manager.start }
      sleep 0.2
      manager
    end

    def initialize(options = {})
      @options = options
      @worker_size = options[:worker_size]
      @worker_task = options[:worker_task]
      @registered_projects = options[:registered_projects]
      at_exit { kill_loader_process }
    end

    def available_for?(project_name)
      registered_projects ? registered_projects.include?(project_name) : false
    end

    def dispatcher_uri=(uri)
      uri.host = ip_from_hostname(uri.host)
      @dispatcher_uri = uri
    end

    def dispatch
      suspend_bonjour do
        sync
        with_clean_env do
          execute_before_fork
          dispatch_loader
        end
      end
    end

    def drb_start
      $PROGRAM_NAME = "specjour listen" if quiet?
      DRb.start_service drb_uri.to_s, self
      at_exit { DRb.stop_service }
    end

    def drb_uri
      @drb_uri ||= begin
        current_uri.scheme = "druby"
        current_uri
      end
    end

    def dispatch_loader
      @loader_pid = fork do
        # at_exit { exit! }
        exec_cmd = "specjour load --printer-uri #{dispatcher_uri} --workers #{worker_size} --task #{worker_task} --project-path #{project_path}"
        exec_cmd << " --preload-spec #{preload_spec}" if preload_spec
        exec_cmd << " --preload-feature #{preload_feature}" if preload_feature
        exec_cmd << " --log" if Specjour.log?
        exec_cmd << " --quiet" if quiet?
        exec exec_cmd
      end
      Process.waitall
    ensure
      kill_loader_process
    end

    def in_project(&block)
      Dir.chdir(project_path, &block)
    end

    def interrupted=(bool)
      Specjour.interrupted = bool
      kill_loader_process
    end

    def kill_loader_process
      if Specjour.interrupted?
        Process.kill('INT', loader_pid) rescue Errno::ESRCH
      else
        Process.kill('TERM', loader_pid) rescue Errno::ESRCH
      end
    end

    def pid
      @pid || Process.pid
    end

    def project_path
      File.join("/tmp", project_name)
    end

    def start
      drb_start
      bonjour_announce
      DRb.thread.join
    end

    def quiet?
      options.has_key? :quiet
    end

    def sync
      unless cmd "rsync -aL --delete --port=8989 #{dispatcher_uri.host}::#{project_name} #{project_path}"
        raise Error, "Rsync Failed."
      end
    end

    protected

    def bonjour_announce
      puts "Workers ready: #{worker_size}."
      puts "Listening for #{registered_projects.join(', ')}"
      unless quiet?
        bonjour_service.register "specjour_manager_#{object_id}", "_#{drb_uri.scheme}._tcp", nil, drb_uri.port
      end
    end

    def bonjour_service
      @bonjour_service ||= DNSSD::Service.new
    end

    def cmd(command)
      puts command
      system command
    end

    def execute_before_fork
      in_project do
        Specjour.load_custom_hooks
        Configuration.before_fork.call
      end
    end

    def stop_bonjour
      bonjour_service.stop
      @bonjour_service = nil
    end

    def suspend_bonjour(&block)
      stop_bonjour
      block.call
      bonjour_announce
    end

    def with_clean_env(&block)
      if defined?(Bundler)
        Bundler.with_clean_env &block
      else
        block.call
      end
    end
  end
end
