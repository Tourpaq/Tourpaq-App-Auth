# Access levels and login methods have the same shape, so one controller serves both (as on WWW); the subclasses
# only say which model. Audited index.access_level.* / index.login_method.*.
class Admin::IndexContent::VocabulariesController < Admin::IndexContent::BaseController
  before_action :set_record, only: %i[edit update destroy]
  helper_method :model, :noun

  def index
    @records = model.ordered.to_a
    @counts = Index::Entry.group(foreign_key).count
    render "admin/index_content/vocabularies/index"
  end

  def new
    @record = model.new(tone: "ok")
    render "admin/index_content/vocabularies/new"
  end

  def create
    @record = model.new(record_params)
    if @record.save
      audit("#{kind}.created", @record, { key: @record.key, label: @record.label, tone: @record.tone })
      redirect_to url_for(action: :index), notice: "#{noun} “#{@record.label}” added."
    else
      render "admin/index_content/vocabularies/new", status: :unprocessable_content
    end
  end

  def edit
    render "admin/index_content/vocabularies/edit"
  end

  def update
    if @record.update(record_params)
      changes = audited_changes(@record)
      audit("#{kind}.updated", @record, { key: @record.key, changes: changes }) if changes.any?
      redirect_to url_for(action: :index), notice: "#{noun} “#{@record.label}” saved."
    else
      render "admin/index_content/vocabularies/edit", status: :unprocessable_content
    end
  end

  def destroy
    used = @record.entries.count
    @record.destroy!
    audit("#{kind}.deleted", @record, { key: @record.key, label: @record.label, entries: used })
    redirect_to url_for(action: :index), notice: "#{noun} “#{@record.label}” deleted."
  end

  private

  def kind = model.model_name.element # "access_level" / "login_method"
  def foreign_key = :"#{kind}_id"

  def set_record
    @record = model.find(params[:id])
  end

  def record_params
    params.require(model.model_name.param_key).permit(:key, :label, :tone, :position)
  end
end
