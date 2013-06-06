# @see http://sunlightlabs.github.io/congress/
namespace :congress do
  def openstates
    if ENV['SUNLIGHT_API_KEY']
      Mongoid.override_session('openstates')
      yield
      Mongoid.override_session(nil)
    else
      abort "ENV['SUNLIGHT_API_KEY'] is not set"
    end
  end

  namespace :api do
    namespace :download do

      desc 'Download legislators from Congress API'
      task legislators: :environment do
        openstates do
          CongressProcessor::Legislators.new.run
        end
      end
    end

    namespace :update do
      desc 'Update metadata from Congress API'
      task metadata: :environment do
        openstates do
        end
      end


      desc 'Update legislators from Congress API'
      task legislators: :environment do
        openstates do
        end
      end

      desc 'Update committees from Congress API'
      task committees: :environment do
        openstates do
        end
      end

      desc 'Update bills from Congress API'
      task bills: :environment do
        openstates do
        end
      end
    end
  end

  private
  class CongressProcessor
    attr_accessor :page, :per_page, :url

    def initialize
      @page = 1
      @per_page = 50
      @url = "#{base_url}/#{plural_type}"
    end

    def params
      { apikey: ENV['SUNLIGHT_API_KEY'], page: page, per_page: per_page }
    end

    def run
      json = JSON.parse(RestClient.get(url, params: params))
      json['results'].each { |result| process result }

      unless json['page']['count'] < per_page
        self.page = page + 1
        run
      end
    end

    class Legislators < CongressProcessor
      def fields
        'bioguide_id,first_name,middle_name,last_name,state,votesmart_id,email,gender,name_suffix,photo_url,twitter_id,chamber,district,party,terms'
      end

      def params
        super.merge({ fields: fields })
      end

      def plural_type
        'legislators'
      end

      def process(result)
        # check for existing person, skip if there is one, at least for now
        unless FederalLegislator.in('us').where(id: result['bioguide_id']).count > 0
          federal_legislator = FederalLegislator.new
          federal_legislator.attributes_from_congress_api result
          federal_legislator.save!
        end
      end
    end

    private
    def base_url
      "http://congress.api.sunlightfoundation.com"
    end
  end
end