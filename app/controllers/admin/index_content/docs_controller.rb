# Docs of the index on the admin host: markdown pages in doc sections. Audited index.doc.created / updated / deleted
# (the body only as "changed").
class Admin::IndexContent::DocsController < Admin::IndexContent::BaseController
  before_action :set_doc, only: %i[edit update destroy]

  def index
    @docs = Index::Doc.includes(:doc_section).ordered.group_by(&:doc_section)
  end

  def new
    @doc = Index::Doc.new(doc_section_id: params[:doc_section_id])
  end

  def create
    @doc = Index::Doc.new(doc_params)
    if @doc.save
      audit("doc.created", @doc, { path: @doc.path, title: @doc.title })
      redirect_to edit_admin_index_doc_path(@doc), notice: "“#{@doc.title}” added."
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit; end

  def update
    if @doc.update(doc_params)
      changes = audited_changes(@doc)
      audit("doc.updated", @doc, { path: @doc.path, changes: changes }) if changes.any?
      redirect_to edit_admin_index_doc_path(@doc), notice: "“#{@doc.title}” saved."
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    @doc.destroy!
    audit("doc.deleted", @doc, { path: @doc.path, title: @doc.title })
    redirect_to admin_index_docs_path, notice: "“#{@doc.title}” deleted."
  end

  private

  def set_doc
    @doc = Index::Doc.find(params[:id])
  end

  def doc_params
    params.require(:index_doc).permit(:title, :slug, :doc_section_id, :summary, :body, :position)
  end
end
