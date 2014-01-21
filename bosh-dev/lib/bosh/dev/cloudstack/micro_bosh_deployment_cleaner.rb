require 'logger'
require 'sequel'
require 'sequel/adapters/sqlite'
require 'cloud/cloudstack'
require 'common/retryable'
require 'bosh/dev/cloudstack'

module Bosh::Dev::Cloudstack
  class MicroBoshDeploymentCleaner
    def initialize(manifest)
      @manifest = manifest
      @logger = Logger.new($stderr)
    end

    def clean
      configure_cpi

      cloud = Bosh::CloudStackCloud::Cloud.new(@manifest.cpi_options)

      servers_collection = cloud.compute.servers

      Bosh::Retryable.new(tries: 20, sleep: 20).retryer do
        # CloudStack does not return deleted servers on subsequent calls
        servers = find_any_matching_servers(servers_collection)

        matching_server_names = servers.map(&:name).join(', ')
        @logger.info("Destroying servers #{matching_server_names}")

        # calling destroy on a server multiple times is ok
        servers.each(&:destroy)

        servers.empty?
      end
    end

    private

    def configure_cpi
      Bosh::Clouds::Config.configure(OpenStruct.new(
        logger: @logger,
        uuid: nil,
        task_checkpoint: nil,
        db: Sequel.sqlite,
      ))
    end

    def find_any_matching_servers(servers_collection)
      # Assumption here is that when director deploys instances
      # it properly tags them with director's name.
      servers_collection.all.select do |server|
        response = server.service.list_tags(resourceid: server.id)['listtagsresponse']
        response.has_key?('tag') &&
        response['tag'].find { |tag|
          (tag['key'] == 'director' || tag['key'] == 'Name') &&
          tag['value'] == @manifest.director_name
        }

      end
    end
  end
end
