class SubjectsController < ApplicationController
  inherit_resources
  belongs_to :jurisdiction, parent_class: Metadatum, finder: :find_by_abbreviation, param: :jurisdiction
  respond_to :html
  respond_to :js, only: :show
  actions :index, :show

  # @note There is no index with both the `subjects` and `session` fields.
  def show
    show! do |format|
      @bills = chain.where(subjects: @subject, session: parent.current_session).includes(:metadatum).desc('action_dates.last').page(params[:page])
      format.js {render partial: 'page'}
    end
  end

private

  # @note MT, RI and WI have inconsistent subject names (typos, etc.).
  def chain
    Bill.in(parent['abbreviation'])
  end

  def collection
    @subjects ||= chain.distinct('subjects').sort
  end

  def resource
    @subject ||= chain.distinct('subjects').find{|subject| subject.parameterize == params[:id]}
  end
end