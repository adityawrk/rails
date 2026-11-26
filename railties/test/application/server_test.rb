# frozen_string_literal: true

require "isolation/abstract_unit"
require "console_helpers"
require "rails/command"

module ApplicationTests
  class ServerTest < ActiveSupport::TestCase
    include ConsoleHelpers

    def setup
      build_app
    end

    def teardown
      teardown_app
    end

    test "restart rails server with custom pid file path" do
      skip "PTY unavailable" unless available_pty?

      File.open("#{app_path}/config/boot.rb", "w") do |f|
        f.puts "ENV['BUNDLE_GEMFILE'] = '#{Bundler.default_gemfile}'"
        f.puts 'require "bundler/setup"'
      end

      primary, replica = PTY.open
      pid = nil

      Bundler.with_original_env do
        pid = Process.spawn("bin/rails server -b localhost -P tmp/dummy.pid", chdir: app_path, in: replica, out: replica, err: replica)
        assert_output("Use Ctrl-C to stop", primary, 100)

        rails("restart")

        assert_output("Restarting", primary, 100)
        assert_output("Listening", primary, 100)
      ensure
        kill(pid) if pid
      end
    end

    # DIAGNOSTIC ONLY, DO NOT MERGE.
    20.times do |i|
      test "restart diag #{i}" do
        skip "PTY unavailable" unless available_pty?

        File.open("#{app_path}/config/boot.rb", "w") do |f|
          f.puts "ENV['BUNDLE_GEMFILE'] = '#{Bundler.default_gemfile}'"
          f.puts 'require "bundler/setup"'
        end

        restart_txt = "#{app_path}/tmp/restart.txt"
        ns = ->(time) { time.strftime("%H:%M:%S.%9N") }

        # Smallest step between distinct mtimes seen while touching for 0.3 s.
        probe = "#{app_path}/tmp/diag_probe.txt"
        mtimes = []
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.3
        while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          FileUtils.touch(probe)
          mtimes << File.stat(probe).mtime
        end
        mtimes.uniq!
        step_ms = mtimes.each_cons(2).map { |a, b| (b - a) * 1000 }.min

        primary, replica = PTY.open
        pid = nil

        Bundler.with_original_env do
          pid = Process.spawn("bin/rails server -b localhost -P tmp/dummy.pid", chdir: app_path, in: replica, out: replica, err: replica)
          assert_output("Use Ctrl-C to stop", primary, 100)
          seen = Time.now
          orig = File.stat(restart_txt).mtime

          rails("restart")
          touched = Time.now
          mtime = File.stat(restart_txt).mtime

          restarted = begin
            assert_output("Restarting", primary, 15)
            true
          rescue Minitest::Assertion
            false
          end

          $stderr.puts "RESTART-DIAG #{i} kernel=#{`uname -r`.strip} ruby=#{RUBY_VERSION} " \
            "fs=#{`stat -f -c %T #{app_path}/tmp`.strip} step_ms=#{step_ms&.round(3).inspect} " \
            "orig=#{ns[orig]} seen=#{ns[seen]} touched=#{ns[touched]} mtime=#{ns[mtime]} " \
            "touched_minus_orig_ms=#{((touched - orig) * 1000).round(3)} " \
            "seen_to_touched_ms=#{((touched - seen) * 1000).round(3)} " \
            "mtime_changed=#{mtime > orig} restarted=#{restarted}"
        ensure
          kill(pid) if pid
        end
      end
    end

    test "run +server+ blocks after the server starts" do
      skip "PTY unavailable" unless available_pty?

      File.open("#{app_path}/config/boot.rb", "w") do |f|
        f.puts "ENV['BUNDLE_GEMFILE'] = '#{Bundler.default_gemfile}'"
        f.puts 'require "bundler/setup"'
      end

      add_to_config(<<~CODE)
        server do
          puts 'Hello world'
        end
      CODE

      primary, replica = PTY.open
      pid = nil

      Bundler.with_original_env do
        pid = Process.spawn("bin/rails server -b localhost", chdir: app_path, in: replica, out: primary, err: replica)
        assert_output("Hello world", primary, 100)
        assert_output("Listening", primary, 100)
      ensure
        kill(pid) if pid
      end
    end

    private
      def kill(pid)
        Process.kill("TERM", pid)
        Process.wait(pid)
      rescue Errno::ESRCH
      end
  end
end
