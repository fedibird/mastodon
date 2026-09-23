# frozen_string_literal: true

require 'rails_helper'

describe Admin::BaseController, type: :controller do
  controller do
    def success
      authorize :dashboard, :index?
      render 'admin/reports/show'
    end
  end

  it 'forbids a user without dashboard permission' do
    routes.draw { get 'success' => 'admin/base#success' }
    sign_in(Fabricate(:user, admin: false, moderator: false))
    get :success

    expect(response).to have_http_status(:forbidden)
  end

  it 'renders admin layout as a moderator' do
    routes.draw { get 'success' => 'admin/base#success' }
    sign_in(user_with_role('Moderator'))
    get :success
    expect(response).to render_template layout: 'admin'
  end

  it 'renders admin layout as an admin' do
    routes.draw { get 'success' => 'admin/base#success' }
    sign_in(user_with_role('Owner'))
    get :success
    expect(response).to render_template layout: 'admin'
  end

  it 'redirects a disabled admin away from the admin UI' do
    routes.draw { get 'success' => 'admin/base#success' }
    user = user_with_role('Owner')
    user.disable!
    sign_in(user)
    get :success

    expect(response).to redirect_to(edit_user_registration_path)
  end
end
