# frozen_string_literal: true

module Pharos
  module Kubeadm
    class ClusterConfig
      PHAROS_DIR = Pharos::Kubeadm::PHAROS_DIR
      AUTHENTICATION_TOKEN_WEBHOOK_CONFIG_DIR = '/etc/kubernetes/authentication'
      AUDIT_CFG_DIR = (PHAROS_DIR + '/audit').freeze
      SECRETS_CFG_DIR = (PHAROS_DIR + '/secrets-encryption').freeze
      SECRETS_CFG_FILE = (SECRETS_CFG_DIR + '/config.yml').freeze
      CLOUD_CFG_DIR = (PHAROS_DIR + '/cloud').freeze
      CLOUD_CFG_FILE = (CLOUD_CFG_DIR + '/cloud-config').freeze
      DEFAULT_ADMISSION_PLUGINS = %w(PodSecurityPolicy NodeRestriction).freeze

      # @param config [Pharos::Config] cluster config
      # @param host [Pharos::Configuration::Host] master host-specific config
      def initialize(config, host)
        @config = config
        @host = host
      end

      # @return [Hash]
      def generate
        config = {
          'apiVersion' => 'kubeadm.k8s.io/v1alpha3',
          'kind' => 'ClusterConfiguration',
          'kubernetesVersion' => Pharos::KUBE_VERSION,
          'imageRepository' => @config.image_repository,
          'apiServerCertSANs' => build_extra_sans,
          'networking' => {
            'serviceSubnet' => @config.network.service_cidr,
            'podSubnet' => @config.network.pod_network_cidr
          },
          'controlPlaneEndpoint' => 'localhost:6443', # client-side loadbalanced kubelets
          'apiServerExtraArgs' => {},
          'controllerManagerExtraArgs' => {
            'horizontal-pod-autoscaler-use-rest-clients' => 'true'
          }
        }

        if @config.cloud && @config.cloud.provider != 'external'
          config['apiServerExtraArgs']['cloud-provider'] = @config.cloud.provider
          config['controllerManagerExtraArgs']['cloud-provider'] = @config.cloud.provider
          if @config.cloud.config
            config['apiServerExtraArgs']['cloud-config'] = CLOUD_CFG_FILE
            config['controllerManagerExtraArgs']['cloud-config'] = CLOUD_CFG_FILE
          end
        end

        # Only configure etcd if the external endpoints are given
        if @config.etcd&.endpoints
          configure_external_etcd(config)
        else
          configure_internal_etcd(config)
        end
        config['apiServerExtraVolumes'] = [
          {
            'name' => 'pharos',
            'hostPath' => PHAROS_DIR,
            'mountPath' => PHAROS_DIR
          }
        ]

        config['controllerManagerExtraVolumes'] = [
          {
            'name' => 'pharos',
            'hostPath' => PHAROS_DIR,
            'mountPath' => PHAROS_DIR
          }
        ]

        # Only if authentication token webhook option are given
        configure_token_webhook(config) if @config.authentication&.token_webhook

        # Configure audit related things if needed
        configure_audit_webhook(config) if @config.audit&.webhook&.server
        configure_audit_file(config) if @config.audit&.file

        configure_admission_plugins(config)

        # Set secrets config location and mount it to api server
        config['apiServerExtraArgs']['experimental-encryption-provider-config'] = SECRETS_CFG_FILE
        config['apiServerExtraVolumes'] << {
          'name' => 'k8s-secrets-config',
          'hostPath' => SECRETS_CFG_DIR,
          'mountPath' => SECRETS_CFG_DIR
        }

        config
      end

      # @return [Array<String>]
      def build_extra_sans
        extra_sans = Set.new(['localhost'])
        extra_sans << @host.address
        extra_sans << @host.private_address if @host.private_address
        extra_sans << @host.private_interface_address if @host.private_interface_address
        extra_sans << @host.api_endpoint if @host.api_endpoint

        extra_sans.to_a
      end

      # @param config [Pharos::Config]
      def configure_internal_etcd(config)
        config['etcd'] = {
          'external' => {
            'endpoints' => @config.etcd_hosts.map { |h|
              "https://#{@config.etcd_peer_address(h)}:2379"
            },
            'certFile'  => '/etc/pharos/pki/etcd/client.pem',
            'caFile'    => '/etc/pharos/pki/ca.pem',
            'keyFile'   => '/etc/pharos/pki/etcd/client-key.pem'
          }
        }
      end

      # @param config [Hash]
      def configure_external_etcd(config)
        config['etcd'] = {
          'external' => {
            'endpoints' => @config.etcd.endpoints
          }
        }

        config['etcd']['external']['certFile'] = '/etc/pharos/etcd/certificate.pem' if @config.etcd.certificate
        config['etcd']['external']['caFile'] = '/etc/pharos/etcd/ca-certificate.pem' if @config.etcd.ca_certificate
        config['etcd']['external']['keyFile'] = '/etc/pharos/etcd/certificate-key.pem' if @config.etcd.key
      end

      # @param config [Hash]
      def configure_token_webhook(config)
        config['apiServerExtraArgs'].merge!(authentication_token_webhook_args(@config.authentication.token_webhook.cache_ttl))
        config['apiServerExtraVolumes'] += volume_mounts_for_authentication_token_webhook
      end

      # @param config [Hash]
      def configure_audit_webhook(config)
        config['apiServerExtraArgs'].merge!(
          "audit-webhook-config-file" => AUDIT_CFG_DIR + '/webhook.yml',
          "audit-policy-file" => AUDIT_CFG_DIR + '/policy.yml'
        )
        config['apiServerExtraVolumes'] += volume_mounts_for_audit_config
      end

      # @return [Array<Hash>]
      def volume_mounts_for_audit_config
        volume_mounts = []
        volume_mount = {
          'name' => 'k8s-audit-webhook',
          'hostPath' => AUDIT_CFG_DIR,
          'mountPath' => AUDIT_CFG_DIR
        }
        volume_mounts << volume_mount

        volume_mounts
      end

      # @param cache_ttl [String]
      def authentication_token_webhook_args(cache_ttl = nil)
        config = {
          'authentication-token-webhook-config-file' => AUTHENTICATION_TOKEN_WEBHOOK_CONFIG_DIR + '/token-webhook-config.yaml'
        }
        config['authentication-token-webhook-cache-ttl'] = cache_ttl if cache_ttl
        config
      end

      # @return [Array<Hash>]
      def volume_mounts_for_authentication_token_webhook
        volume_mounts = []
        volume_mount = {
          'name' => 'k8s-auth-token-webhook',
          'hostPath' => AUTHENTICATION_TOKEN_WEBHOOK_CONFIG_DIR,
          'mountPath' => AUTHENTICATION_TOKEN_WEBHOOK_CONFIG_DIR
        }
        volume_mounts << volume_mount
        volume_mounts
      end

      # @param config [Hash]
      def configure_audit_file(config)
        config['apiServerExtraArgs'].merge!(
          "audit-log-path" => @config.audit.file.path,
          "audit-log-maxage" => @config.audit.file.max_age.to_s,
          "audit-log-maxbackup" => @config.audit.file.max_backups.to_s,
          "audit-log-maxsize" => @config.audit.file.max_size.to_s,
          "audit-policy-file" => AUDIT_CFG_DIR + '/policy.yml'
        )
        base_dir = File.dirname(@config.audit.file.path)
        config['apiServerExtraVolumes'] += [{
          'name' => 'k8s-audit-file',
          'hostPath' => base_dir,
          'mountPath' => base_dir,
          'writable' => true
        }]
        config['apiServerExtraVolumes'] += volume_mounts_for_audit_config
      end

      # @param config [Hash]
      def configure_admission_plugins(config)
        disabled_plugins = @config.admission_plugins&.reject(&:enabled)&.map(&:name) || []
        enabled_plugins = DEFAULT_ADMISSION_PLUGINS.reject{ |p| disabled_plugins.include?(p) } + (@config.admission_plugins&.select(&:enabled)&.map(&:name) || [])

        config['apiServerExtraArgs']['enable-admission-plugins'] = enabled_plugins.uniq.join(',') unless enabled_plugins.empty?
        config['apiServerExtraArgs']['disable-admission-plugins'] = disabled_plugins.uniq.join(',') unless disabled_plugins.empty?
      end
    end
  end
end
