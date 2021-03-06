# @see http://sunlightlabs.github.io/openstates-api/
# @see https://github.com/sunlightlabs/billy/wiki/Differences-between-the-API-and-MongoDB
namespace :openstates do
  def with_api_key
    if Metadatum::State.api_key
      yield
   else
      abort "Metadatum::State.api_key is not set"
    end
  end

  def tmp_dir
    dir = Rails.root.join('tmp')
    Dir.mkdir(dir) unless File.exists?(dir)
    abort "#{dir} is not a directory" unless File.directory?(dir)
    dir
  end

  # http://sunlightlabs.github.io/openstates-api/metadata.html
  def metadata_url
    "#{Metadatum::State.api_base_url}?fields=latest_json_date,latest_json_url&apikey=#{Metadatum::State.api_key}"
  end

  def extract_from_json_document(file_name)

    # Read the input JSON into a string
    begin
      json_str = File.open(file_name) { |f| f.read }
    rescue Exception => e
      puts e.message
      return nil, nil
    end

    # Deserialize JSON string into a Ruby object
    begin
      obj = JSON(json_str)
    rescue Exception => e
      puts e.message
      return nil, nil
    end

    return obj['id'], obj['updated_at']
  end

  desc 'Adds metadata from OpenStates'
  task add_metadata: :environment do
    Metadatum::State.create_states_if_none
  end

  desc 'Update metadata, legislators, committees and bills from OpenStates'
  task update: :environment do
    with_api_key do
      # @todo mixed strategy using both JSON downloads and API
    end
  end

  namespace :json do
    desc 'Download OpenStates JSON'
    task download: :environment do
      Mongoid.raise_not_found_error = false

      with_api_key do
        begin
          metadata = JSON.parse(RestClient.get(metadata_url))
        rescue Exception => e
          abort "Error downloading metadata: #{metadata_url}\n#{e.message}"
        end

        if ENV['ONLY']
          only_states = ENV['ONLY'].split(',')
          metadata = metadata.keep_if { |m| only_states.include?(m['id']) }
        end

        metadata.each do |remote|
          file_path = File.join(tmp_dir, File.basename(remote['latest_json_url']))
          local = Metadatum.find(remote['id'])

          if ! File.exist?(file_path) && (local.nil? || local['latest_json_date'].to_i < Time.parse(remote['latest_json_date'] + 'UTC').to_i)
            puts "Downloading #{remote['id']}..."
            rc = system("curl --silent --show-error -o #{file_path} #{remote['latest_json_url']}")
            unless rc == true
              FileUtils.rm_rf("#{file_path}")  # Ensure no partial or invalid download survives
              abort "Error downloading #{remote['latest_json_url']}"
            end
          end

        end
      end
    end

    # Inspired by https://gist.github.com/erik-eide/1233435
    # @todo report any documents that are in the local DB but not in the JSON downloads (e.g. could be a merged legislator)
    desc 'Update legislators, committees and bills from OpenStates JSON downloads'
    task update: :download do
      require 'find'
      require 'fileutils'

      db = OpenstatesDatabase.new

      with_api_key do

        # Process each zip file we have
        Dir.glob("#{tmp_dir}/*.zip").each do |zip_file|
           dirs_in_zip = `unzip -l #{zip_file} | egrep -v 'Archive|Length|----|files$' | awk '{print $4}' | awk -F/ '{print $1}' | sort -u`.scan(/^.*$/)

           # Ensure a clean slate before unzipping
           dirs_in_zip.each { |zip_dir_name| FileUtils.rm_rf("#{tmp_dir}/#{zip_dir_name}") }

           # Unzip
           puts "Unzipping #{zip_file}"
           unzip = "unzip -d #{tmp_dir} #{zip_file}"

           rc = system("#{unzip} 1>/dev/null")
           abort "unzip failed: #{unzip}" unless rc

           File.delete(zip_file)

           # Traverse the unzipped directories
           # http://www.ruby-doc.org/stdlib-1.9.3/libdoc/find/rdoc/Find.html
           dirs_in_zip.each do |zip_dir_name|
             zip_dir = "#{tmp_dir}/#{zip_dir_name}"

             Find.find(zip_dir) do |path|

               # Process a directory
               if FileTest.directory?(path)
                 File.basename(path)[0] == '.' ? Find.prune : next
                 abort "Should never reach this"
               end

               mongo_doc = path
               puts "  #{mongo_doc.sub("#{tmp_dir}/", '')}"
               json_id, json_updated_at = extract_from_json_document(mongo_doc)

               ## @todo Skip updating document if database updated_at is newer
               #objs = Committee.where(id: json_id)
               #abort "#{objs.count} entries of committee #{json_id}" unless objs.count == 1
               #next if json_updated_at.to_i <= objs.first.updated_at.to_i

               # Modify the downloaded JSON document to force _id to be the same as id
               mongo_doc_copy = "#{mongo_doc}.orig"
               FileUtils.mv(mongo_doc, mongo_doc_copy)
               File.open(mongo_doc, 'w') { |f| f.write(File.read(mongo_doc_copy).gsub(/"id":/, "\"_id\": \"#{json_id}\", \"id\":")) }
               FileUtils.rm_rf(mongo_doc_copy)

               # Import the document into MongoDB
               # Assume directory name maps to MongoDB collection name
               # http://docs.mongodb.org/manual/reference/program/mongoimport/
               # http://docs.mongodb.org/manual/core/import-export/
               mongoimport = "mongoimport --stopOnError #{db.connection_options} -c #{zip_dir_name} --type json --file \"#{mongo_doc}\" --upsert"

               rc = system("#{mongoimport} 1>/dev/null")
               unless rc
                 puts mongoimport
                 system("#{mongoimport}")
                 abort
               end

               File.delete(mongo_doc) if File.exists?(mongo_doc)
             end

             FileUtils.rm_rf("#{zip_dir}")
           end
        end
      end
    end

  end

  namespace :api do
    desc 'Update metadata from OpenStates API'
    task metadata: :environment do
      with_api_key do
        # @todo 1 call
      end
    end


    desc 'Update legislators from OpenStates API'
    task legislators: :environment do
      with_api_key do
        # @todo 1 call per state
      end
    end

    desc 'Update committees from OpenStates API'
    task committees: :environment do
      with_api_key do
        # @todo 1 call
      end
    end

    desc 'Update bills from OpenStates API'
    task bills: :environment do
      with_api_key do
        # @todo use updated_since
        # complete docs at https://github.com/sunlightlabs/billy/wiki/Differences-between-the-API-and-MongoDB
      end
    end
  end

  private
  class OpenstatesDatabase
    attr_reader :config, :session, :host_num

    # Inspired by mongodb.rake
    def initialize(params = {})
      @config ||= begin
        path = Rails.root.join('config', 'mongoid.yml')
        config = YAML.load(ERB.new(File.read(path)).result)
        abort "Invalid mongoid config: #{path}" unless config.is_a?(Hash) && !config[Rails.env].blank?
        config
      end
      @session  = params['session'].blank?  ? 'default' : params['session']
      @host_num = params['host_num'].blank? ? 0         : params['host_num'].to_i
      abort "host_num #{params['host_num']} cannot exceed #{hosts.count-1}" if @host_num >= hosts.count
    end

    def hosts
      config[Rails.env]['sessions'][session]['hosts']
    end

    def host
      hosts.blank? ? nil : hosts[host_num].split(':')[0]
    end

    def port
      hosts.blank? ? nil : hosts[host_num].split(':')[1]
    end

    def username
      config[Rails.env]['sessions'][session]['username']
    end

    def password
      config[Rails.env]['sessions'][session]['password']
    end

    def database
      config[Rails.env]['sessions'][session]['database']
    end

    # Inspired by https://gist.github.com/erik-eide/1233435
    def connection_options
      conn_string = ''
      conn_string += "--host #{host} "         unless host.blank?
      conn_string += "--port #{port} "         unless port.blank?
      conn_string += "--username #{username} " unless username.blank?
      conn_string += "--password #{password} " unless password.blank?
      conn_string += "--db #{database} "       unless database.blank?
      conn_string
    end

  end # OpenstatesDatabase

end
