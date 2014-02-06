require 'spec_helper'
require 'fog'
require 'fog/cloudstack/models/compute/servers'
require 'bosh/dev/cloudstack/micro_bosh_deployment_cleaner'
require 'bosh/dev/cloudstack/micro_bosh_deployment_manifest'

module Bosh::Dev::Cloudstack
  describe MicroBoshDeploymentCleaner do
    subject(:cleaner) { described_class.new(manifest) }

    let(:manifest) do
      instance_double(
        'Bosh::Dev::Cloudstack::MicroBoshDeploymentManifest',
        director_name: 'fake-director-name',
        cpi_options:   'fake-cpi-options',
      )
    end

    describe '#clean' do
      before { Bosh::CloudStackCloud::Cloud.stub(new: cloud) }
      let(:cloud) { instance_double('Bosh::CloudStackCloud::Cloud') }

      before { cloud.stub(compute: compute) }
      let(:compute) { double('Fog::Compute::Cloudstack::Real') }

      before { compute.stub(servers: servers_collection) }
      let(:servers_collection) { instance_double('Fog::Compute::Cloudstack::Servers', all: []) }

      before { Logger.stub(new: logger) }
      let(:logger) { instance_double('Logger', info: nil) }

      it 'uses cloudstack cloud with cpi options from the manifest' do
        Bosh::CloudStackCloud::Cloud
          .should_receive(:new)
          .with('fake-cpi-options')
          .and_return(cloud)
        cleaner.clean
      end

      context 'when matching servers are found' do
        before { Bosh::Retryable.stub(new: retryable) }
        let(:retryable) { instance_double('Bosh::Retryable') }

        it 'terminates servers that have specific microbosh tag name' do
          server_with_non_matching = instance_double(
            'Fog::Compute::Cloudstack::Server',
            name: 'fake-name1',
            id: 'fake-id1',
            service: compute,
          )
          expect(cleaner).to_not receive(:clean_server).with(server_with_non_matching)

          compute.should_receive(:list_tags)
            .with(resourceid: 'fake-id1')
            .and_return(make_tag('director', 'non-matching-tag-value'))
          server_with_matching = instance_double(
            'Fog::Compute::Cloudstack::Server',
            name: 'fake-name2',
            id: 'fake-id2',
            service: compute,
          )
          expect(cleaner).to receive(:clean_server).with(server_with_matching)

          compute.should_receive(:list_tags)
            .with(resourceid: 'fake-id2')
            .and_return(make_tag('director', 'fake-director-name'))
          microbosh_server = instance_double(
            'Fog::Compute::Cloudstack::Server',
            name: 'fake-name3',
            id: 'fake-id3',
            service: compute,
          )
          expect(cleaner).to receive(:clean_server).with(microbosh_server)

          compute.should_receive(:list_tags)
            .with(resourceid: 'fake-id3')
            .and_return(make_tag('Name', 'fake-director-name'))

          retryable.stub(:retryer).and_yield

          servers_collection.stub(all: [
            server_with_non_matching,
            server_with_matching,
            microbosh_server,
          ])

          cleaner.clean
        end

        it 'waits for all the matching servers to be deleted' +
           '(deleted servers are gone from the returned list)' do
          compute.should_receive(:list_tags)
            .with(resourceid: 'fake-id2')
            .and_return(make_tag('director', 'fake-director-name'))

          server1 = instance_double(
            'Fog::Compute::Cloudstack::Server',
            name: 'fake-name1',
            id: 'fake-id1',
            destroy: nil,
            service: compute,
          )

          server2 = instance_double(
            'Fog::Compute::Cloudstack::Server',
            name: 'fake-name2',
            id: 'fake-id2',
            destroy: nil,
            service: compute,
          )

          compute
            .stub(:volumes)
            .and_return([])

          %w{fake-id1 fake-id2}.each do |id|
            compute.should_receive(:list_tags)
              .with(resourceid: id)
              .and_return(make_tag('director', 'fake-director-name'))
          end

          retryable.should_receive(:retryer) do |&blk|
            servers_collection.stub(all: [server1, server2])
            blk.call.should be(false)

            servers_collection.stub(all: [server2])
            blk.call.should be(false)

            servers_collection.stub(all: [])
            blk.call.should be(true)
          end

          cleaner.clean
        end

        def make_tag(key, value)
          {
            'listtagsresponse' => {
              'tag' => [
                { 'key' => key, 'value' => value }
              ]
            }
          }
        end
      end

      context 'when matching servers are not found' do
        it 'finishes without waiting for anything' do
          servers_collection.stub(all: [])
          cleaner.clean
        end
      end
    end

    describe '#clean_server' do
      let(:compute) do
        double(
          'Fog::Compute::Cloudstack::Real',
          volumes: [volume1, volume2]
        )
      end

      let(:server) do
        instance_double('Fog::Compute::Cloudstack::Server', {
          id: 'fake-server-id1',
          destroy: nil,
          service: compute
        })
      end

      let(:volume1) do
        instance_double('Fog::Compute::Cloudstack::Volume', {
          type: 'ROOT',
          server_id: 'fake-server-id1',
          detach: nil,
        })
      end

      let(:volume2) do
        instance_double('Fog::Compute::Cloudstack::Volume', {
          type: 'DATA',
          server_id: 'fake-server-id1',
          detach: nil,
        })
      end

      before { Bosh::Retryable.stub(new: retryable) }
      let(:retryable) { instance_double('Bosh::Retryable') }

      it 'detaches and destroys any volumes attached to it and then it destroys the server' do
        retryable.stub(:retryer).and_yield

        expect(volume1).not_to receive(:detach).with(no_args)
        expect(volume1).not_to receive(:destroy).with(no_args)

        expect(volume2).to receive(:detach).with(no_args).ordered
        expect(volume2).to receive(:destroy).with(no_args).ordered

        expect(server).to receive(:destroy).with(no_args).ordered

        cleaner.clean_server(server)
      end

      it 'retries to destroy volume until it succeeds' do
        expect(Bosh::Retryable).to receive(:new)
          .with(tries: 10, sleep: 5, on: [Excon::Errors::BadRequest])
          .and_return(retryable)

        blks = []
        allow(retryable).to receive(:retryer) { |&blk| blks << blk }

        cleaner.clean_server(server)

        expect(volume2).to receive(:destroy).with(no_args)
        blks.each(&:call)
      end
    end
  end
end
