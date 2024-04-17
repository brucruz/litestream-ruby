require_relative "upstream"

module Litestream
  module Commands
    DEFAULT_DIR = File.expand_path(File.join(__dir__, "..", "..", "exe"))
    GEM_NAME = "litestream"

    # raised when the host platform is not supported by upstream litestream's binary releases
    UnsupportedPlatformException = Class.new(StandardError)

    # raised when the litestream executable could not be found where we expected it to be
    ExecutableNotFoundException = Class.new(StandardError)

    # raised when LITESTREAM_INSTALL_DIR does not exist
    DirectoryNotFoundException = Class.new(StandardError)

    # raised when a litestream command requires a database argument but it isn't provided
    DatabaseRequiredException = Class.new(StandardError)

    class << self
      def platform
        [:cpu, :os].map { |m| Gem::Platform.local.send(m) }.join("-")
      end

      def executable(exe_path: DEFAULT_DIR)
        litestream_install_dir = ENV["LITESTREAM_INSTALL_DIR"]
        if litestream_install_dir
          if File.directory?(litestream_install_dir)
            warn "NOTE: using LITESTREAM_INSTALL_DIR to find litestream executable: #{litestream_install_dir}"
            exe_path = litestream_install_dir
            exe_file = File.expand_path(File.join(litestream_install_dir, "litestream"))
          else
            raise DirectoryNotFoundException, <<~MESSAGE
              LITESTREAM_INSTALL_DIR is set to #{litestream_install_dir}, but that directory does not exist.
            MESSAGE
          end
        else
          if Litestream::Upstream::NATIVE_PLATFORMS.keys.none? { |p| Gem::Platform.match_gem?(Gem::Platform.new(p), GEM_NAME) }
            raise UnsupportedPlatformException, <<~MESSAGE
              litestream-ruby does not support the #{platform} platform
              Please install litestream following instructions at https://litestream.io/install
            MESSAGE
          end

          exe_file = Dir.glob(File.expand_path(File.join(exe_path, "*", "litestream"))).find do |f|
            Gem::Platform.match_gem?(Gem::Platform.new(File.basename(File.dirname(f))), GEM_NAME)
          end
        end

        if exe_file.nil? || !File.exist?(exe_file)
          raise ExecutableNotFoundException, <<~MESSAGE
            Cannot find the litestream executable for #{platform} in #{exe_path}

            If you're using bundler, please make sure you're on the latest bundler version:

                gem install bundler
                bundle update --bundler

            Then make sure your lock file includes this platform by running:

                bundle lock --add-platform #{platform}
                bundle install

            See `bundle lock --help` output for details.

            If you're still seeing this message after taking those steps, try running
            `bundle config` and ensure `force_ruby_platform` isn't set to `true`. See
            https://github.com/fractaledmind/litestream-ruby#check-bundle_force_ruby_platform
            for more details.
          MESSAGE
        end

        exe_file
      end

      def replicate(argv = {})
        execute("replicate", argv)
      end

      def restore(database, argv = {})
        raise DatabaseRequiredException, "database argument is required for restore command, e.g. litestream:restore -- --database=path/to/database.sqlite" if database.nil?

        dir, file = File.split(database)
        ext = File.extname(file)
        base = File.basename(file, ext)
        now = Time.now.utc.strftime("%Y%m%d%H%M%S")

        args = {
          "-o" => File.join(dir, "#{base}-#{now}#{ext}")
        }.merge(argv)

        execute("restore", args, database)
      end

      def databases(argv = {})
        execute("databases", argv)
      end

      def generations(database, argv = {})
        raise DatabaseRequiredException, "database argument is required for generations command, e.g. litestream:generations -- --database=path/to/database.sqlite" if database.nil?

        execute("generations", argv, database)
      end

      def snapshots(database, argv = {})
        raise DatabaseRequiredException, "database argument is required for snapshots command, e.g. litestream:snapshots -- --database=path/to/database.sqlite" if database.nil?

        execute("snapshots", argv, database)
      end

      private

      def execute(command, argv = {}, database = nil)
        if Litestream.configuration
          ENV["LITESTREAM_REPLICA_BUCKET"] ||= Litestream.configuration.replica_bucket
          ENV["LITESTREAM_ACCESS_KEY_ID"] ||= Litestream.configuration.replica_key_id
          ENV["LITESTREAM_SECRET_ACCESS_KEY"] ||= Litestream.configuration.replica_access_key
        end

        args = {
          "--config" => Rails.root.join("config", "litestream.yml").to_s
        }.merge(argv).to_a.flatten.compact
        cmd = [executable, command, *args, database].compact

        # To release the resources of the Ruby process, just fork and exit.
        # The forked process executes litestream and replaces itself.
        if fork.nil?
          puts cmd.inspect if ENV["DEBUG"]
          exec(*cmd)
        end
      end
    end
  end
end
