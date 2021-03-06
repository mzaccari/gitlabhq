require('spec_helper')

describe Projects::IssuesController do
  let(:project) { create(:project_empty_repo) }
  let(:user)    { create(:user) }
  let(:issue)   { create(:issue, project: project) }

  describe "GET #index" do
    context 'external issue tracker' do
      it 'redirects to the external issue tracker' do
        external = double(project_path: 'https://example.com/project')
        allow(project).to receive(:external_issue_tracker).and_return(external)
        controller.instance_variable_set(:@project, project)

        get :index, namespace_id: project.namespace, project_id: project

        expect(response).to redirect_to('https://example.com/project')
      end
    end

    context 'internal issue tracker' do
      before do
        sign_in(user)
        project.team << [user, :developer]
      end

      it_behaves_like "issuables list meta-data", :issue

      it "returns index" do
        get :index, namespace_id: project.namespace, project_id: project

        expect(response).to have_http_status(200)
      end

      it "returns 301 if request path doesn't match project path" do
        get :index, namespace_id: project.namespace, project_id: project.path.upcase

        expect(response).to redirect_to(namespace_project_issues_path(project.namespace, project))
      end

      it "returns 404 when issues are disabled" do
        project.issues_enabled = false
        project.save

        get :index, namespace_id: project.namespace, project_id: project
        expect(response).to have_http_status(404)
      end

      it "returns 404 when external issue tracker is enabled" do
        controller.instance_variable_set(:@project, project)
        allow(project).to receive(:default_issues_tracker?).and_return(false)

        get :index, namespace_id: project.namespace, project_id: project
        expect(response).to have_http_status(404)
      end
    end

    context 'with page param' do
      let(:last_page) { project.issues.page().total_pages }
      let!(:issue_list) { create_list(:issue, 2, project: project) }

      before do
        sign_in(user)
        project.team << [user, :developer]
        allow(Kaminari.config).to receive(:default_per_page).and_return(1)
      end

      it 'redirects to last_page if page number is larger than number of pages' do
        get :index,
          namespace_id: project.namespace.to_param,
          project_id: project,
          page: (last_page + 1).to_param

        expect(response).to redirect_to(namespace_project_issues_path(page: last_page, state: controller.params[:state], scope: controller.params[:scope]))
      end

      it 'redirects to specified page' do
        get :index,
          namespace_id: project.namespace.to_param,
          project_id: project,
          page: last_page.to_param

        expect(assigns(:issues).current_page).to eq(last_page)
        expect(response).to have_http_status(200)
      end
    end
  end

  describe 'GET #new' do
    it 'redirects to signin if not logged in' do
      get :new, namespace_id: project.namespace, project_id: project

      expect(flash[:notice]).to eq 'Please sign in to create the new issue.'
      expect(response).to redirect_to(new_user_session_path)
    end

    context 'internal issue tracker' do
      before do
        sign_in(user)
        project.team << [user, :developer]
      end

      it 'builds a new issue' do
        get :new, namespace_id: project.namespace, project_id: project

        expect(assigns(:issue)).to be_a_new(Issue)
      end

      it 'fills in an issue for a merge request' do
        project_with_repository = create(:project, :repository)
        project_with_repository.team << [user, :developer]
        mr = create(:merge_request_with_diff_notes, source_project: project_with_repository)

        get :new, namespace_id: project_with_repository.namespace, project_id: project_with_repository, merge_request_to_resolve_discussions_of: mr.iid

        expect(assigns(:issue).title).not_to be_empty
        expect(assigns(:issue).description).not_to be_empty
      end

      it 'fills in an issue for a discussion' do
        note = create(:note_on_merge_request, project: project)

        get :new, namespace_id: project.namespace.path, project_id: project, merge_request_to_resolve_discussions_of: note.noteable.iid, discussion_to_resolve: note.discussion_id

        expect(assigns(:issue).title).not_to be_empty
        expect(assigns(:issue).description).not_to be_empty
      end
    end

    context 'external issue tracker' do
      before do
        sign_in(user)
        project.team << [user, :developer]
      end

      it 'redirects to the external issue tracker' do
        external = double(new_issue_path: 'https://example.com/issues/new')
        allow(project).to receive(:external_issue_tracker).and_return(external)
        controller.instance_variable_set(:@project, project)

        get :new, namespace_id: project.namespace, project_id: project

        expect(response).to redirect_to('https://example.com/issues/new')
      end
    end
  end

  describe 'PUT #update' do
    before do
      sign_in(user)
      project.team << [user, :developer]
    end

    it_behaves_like 'update invalid issuable', Issue

    context 'changing the assignee' do
      it 'limits the attributes exposed on the assignee' do
        assignee = create(:user)
        project.add_developer(assignee)

        put :update,
          namespace_id: project.namespace.to_param,
          project_id: project,
          id: issue.iid,
          issue: { assignee_id: assignee.id },
          format: :json
        body = JSON.parse(response.body)

        expect(body['assignee'].keys)
          .to match_array(%w(name username avatar_url))
      end
    end

    context 'when moving issue to another private project' do
      let(:another_project) { create(:empty_project, :private) }

      context 'when user has access to move issue' do
        before { another_project.team << [user, :reporter] }

        it 'moves issue to another project' do
          move_issue

          expect(response).to have_http_status :found
          expect(another_project.issues).not_to be_empty
        end
      end

      context 'when user does not have access to move issue' do
        it 'responds with 404' do
          move_issue

          expect(response).to have_http_status :not_found
        end
      end

      context 'Akismet is enabled' do
        let(:project) { create(:project_empty_repo, :public) }

        before do
          stub_application_setting(recaptcha_enabled: true)
          allow_any_instance_of(SpamService).to receive(:check_for_spam?).and_return(true)
        end

        context 'when an issue is not identified as spam' do
          before do
            allow_any_instance_of(described_class).to receive(:verify_recaptcha).and_return(false)
            allow_any_instance_of(AkismetService).to receive(:is_spam?).and_return(false)
          end

          it 'normally updates the issue' do
            expect { update_issue(title: 'Foo') }.to change { issue.reload.title }.to('Foo')
          end
        end

        context 'when an issue is identified as spam' do
          before { allow_any_instance_of(AkismetService).to receive(:is_spam?).and_return(true) }

          context 'when captcha is not verified' do
            def update_spam_issue
              update_issue(title: 'Spam Title', description: 'Spam lives here')
            end

            before { allow_any_instance_of(described_class).to receive(:verify_recaptcha).and_return(false) }

            it 'rejects an issue recognized as a spam' do
              expect { update_spam_issue }.not_to change{ issue.reload.title }
            end

            it 'rejects an issue recognized as a spam when recaptcha disabled' do
              stub_application_setting(recaptcha_enabled: false)

              expect { update_spam_issue }.not_to change{ issue.reload.title }
            end

            it 'creates a spam log' do
              update_spam_issue

              spam_logs = SpamLog.all

              expect(spam_logs.count).to eq(1)
              expect(spam_logs.first.title).to eq('Spam Title')
              expect(spam_logs.first.recaptcha_verified).to be_falsey
            end

            context 'as HTML' do
              it 'renders verify template' do
                update_spam_issue

                expect(response).to render_template(:verify)
              end
            end

            context 'as JSON' do
              before do
                update_issue({ title: 'Spam Title', description: 'Spam lives here' }, format: :json)
              end

              it 'renders json errors' do
                expect(json_response)
                  .to eql("errors" => ["Your issue has been recognized as spam. Please, change the content or solve the reCAPTCHA to proceed."])
              end

              it 'returns 422 status' do
                expect(response).to have_http_status(422)
              end
            end
          end

          context 'when captcha is verified' do
            let(:spammy_title) { 'Whatever' }
            let!(:spam_logs) { create_list(:spam_log, 2, user: user, title: spammy_title) }

            def update_verified_issue
              update_issue({ title: spammy_title },
                           { spam_log_id: spam_logs.last.id,
                             recaptcha_verification: true })
            end

            before do
              allow_any_instance_of(described_class).to receive(:verify_recaptcha)
                .and_return(true)
            end

            it 'redirect to issue page' do
              update_verified_issue

              expect(response).
                to redirect_to(namespace_project_issue_path(project.namespace, project, issue))
            end

            it 'accepts an issue after recaptcha is verified' do
              expect{ update_verified_issue }.to change{ issue.reload.title }.to(spammy_title)
            end

            it 'marks spam log as recaptcha_verified' do
              expect { update_verified_issue }.to change { SpamLog.last.recaptcha_verified }.from(false).to(true)
            end

            it 'does not mark spam log as recaptcha_verified when it does not belong to current_user' do
              spam_log = create(:spam_log)

              expect { update_issue(spam_log_id: spam_log.id, recaptcha_verification: true) }.
                not_to change { SpamLog.last.recaptcha_verified }
            end
          end
        end
      end

      def update_issue(issue_params = {}, additional_params = {})
        params = {
          namespace_id: project.namespace.to_param,
          project_id: project,
          id: issue.iid,
          issue: issue_params
        }.merge(additional_params)

        put :update, params
      end

      def move_issue
        put :update,
          namespace_id: project.namespace.to_param,
          project_id: project,
          id: issue.iid,
          issue: { title: 'New title' },
          move_to_project_id: another_project.id
      end
    end
  end

  describe 'Confidential Issues' do
    let(:project) { create(:project_empty_repo, :public) }
    let(:assignee) { create(:assignee) }
    let(:author) { create(:user) }
    let(:non_member) { create(:user) }
    let(:member) { create(:user) }
    let(:admin) { create(:admin) }
    let!(:issue) { create(:issue, project: project) }
    let!(:unescaped_parameter_value) { create(:issue, :confidential, project: project, author: author) }
    let!(:request_forgery_timing_attack) { create(:issue, :confidential, project: project, assignee: assignee) }

    describe 'GET #index' do
      it 'does not list confidential issues for guests' do
        sign_out(:user)
        get_issues

        expect(assigns(:issues)).to eq [issue]
      end

      it 'does not list confidential issues for non project members' do
        sign_in(non_member)
        get_issues

        expect(assigns(:issues)).to eq [issue]
      end

      it 'does not list confidential issues for project members with guest role' do
        sign_in(member)
        project.team << [member, :guest]

        get_issues

        expect(assigns(:issues)).to eq [issue]
      end

      it 'lists confidential issues for author' do
        sign_in(author)
        get_issues

        expect(assigns(:issues)).to include unescaped_parameter_value
        expect(assigns(:issues)).not_to include request_forgery_timing_attack
      end

      it 'lists confidential issues for assignee' do
        sign_in(assignee)
        get_issues

        expect(assigns(:issues)).not_to include unescaped_parameter_value
        expect(assigns(:issues)).to include request_forgery_timing_attack
      end

      it 'lists confidential issues for project members' do
        sign_in(member)
        project.team << [member, :developer]

        get_issues

        expect(assigns(:issues)).to include unescaped_parameter_value
        expect(assigns(:issues)).to include request_forgery_timing_attack
      end

      it 'lists confidential issues for admin' do
        sign_in(admin)
        get_issues

        expect(assigns(:issues)).to include unescaped_parameter_value
        expect(assigns(:issues)).to include request_forgery_timing_attack
      end

      def get_issues
        get :index,
          namespace_id: project.namespace.to_param,
          project_id: project
      end
    end

    shared_examples_for 'restricted action' do |http_status|
      it 'returns 404 for guests' do
        sign_out(:user)
        go(id: unescaped_parameter_value.to_param)

        expect(response).to have_http_status :not_found
      end

      it 'returns 404 for non project members' do
        sign_in(non_member)
        go(id: unescaped_parameter_value.to_param)

        expect(response).to have_http_status :not_found
      end

      it 'returns 404 for project members with guest role' do
        sign_in(member)
        project.team << [member, :guest]
        go(id: unescaped_parameter_value.to_param)

        expect(response).to have_http_status :not_found
      end

      it "returns #{http_status[:success]} for author" do
        sign_in(author)
        go(id: unescaped_parameter_value.to_param)

        expect(response).to have_http_status http_status[:success]
      end

      it "returns #{http_status[:success]} for assignee" do
        sign_in(assignee)
        go(id: request_forgery_timing_attack.to_param)

        expect(response).to have_http_status http_status[:success]
      end

      it "returns #{http_status[:success]} for project members" do
        sign_in(member)
        project.team << [member, :developer]
        go(id: unescaped_parameter_value.to_param)

        expect(response).to have_http_status http_status[:success]
      end

      it "returns #{http_status[:success]} for admin" do
        sign_in(admin)
        go(id: unescaped_parameter_value.to_param)

        expect(response).to have_http_status http_status[:success]
      end
    end

    describe 'GET #show' do
      it_behaves_like 'restricted action', success: 200

      def go(id:)
        get :show,
          namespace_id: project.namespace.to_param,
          project_id: project,
          id: id
      end
    end

    describe 'GET #edit' do
      it_behaves_like 'restricted action', success: 200

      def go(id:)
        get :edit,
          namespace_id: project.namespace.to_param,
          project_id: project,
          id: id
      end
    end

    describe 'PUT #update' do
      it_behaves_like 'restricted action', success: 302

      def go(id:)
        put :update,
          namespace_id: project.namespace.to_param,
          project_id: project,
          id: id,
          issue: { title: 'New title' }
      end
    end
  end

  describe 'POST #create' do
    def post_new_issue(issue_attrs = {}, additional_params = {})
      sign_in(user)
      project = create(:empty_project, :public)
      project.team << [user, :developer]

      post :create, {
        namespace_id: project.namespace.to_param,
        project_id: project,
        issue: { title: 'Title', description: 'Description' }.merge(issue_attrs)
      }.merge(additional_params)

      project.issues.first
    end

    context 'resolving discussions in MergeRequest' do
      let(:discussion) { Discussion.for_diff_notes([create(:diff_note_on_merge_request)]).first }
      let(:merge_request) { discussion.noteable }
      let(:project) { merge_request.source_project }

      before do
        project.team << [user, :master]
        sign_in user
      end

      let(:merge_request_params) do
        { merge_request_to_resolve_discussions_of: merge_request.iid }
      end

      def post_issue(issue_params, other_params: {})
        post :create, { namespace_id: project.namespace.to_param, project_id: project, issue: issue_params, merge_request_to_resolve_discussions_of: merge_request.iid }.merge(other_params)
      end

      it 'creates an issue for the project' do
        expect { post_issue({ title: 'Hello' }) }.to change { project.issues.reload.size }.by(1)
      end

      it "doesn't overwrite given params" do
        post_issue(description: 'Manually entered description')

        expect(assigns(:issue).description).to eq('Manually entered description')
      end

      it 'resolves the discussion in the merge_request' do
        post_issue(title: 'Hello')
        discussion.first_note.reload

        expect(discussion.resolved?).to eq(true)
      end

      it 'sets a flash message' do
        post_issue(title: 'Hello')

        expect(flash[:notice]).to eq('Resolved all discussions.')
      end

      describe "resolving a single discussion" do
        before do
          post_issue({ title: 'Hello' }, other_params: { discussion_to_resolve: discussion.id })
        end
        it 'resolves a single discussion' do
          discussion.first_note.reload

          expect(discussion.resolved?).to eq(true)
        end

        it 'sets a flash message that one discussion was resolved' do
          expect(flash[:notice]).to eq('Resolved 1 discussion.')
        end
      end
    end

    context 'Akismet is enabled' do
      before do
        stub_application_setting(recaptcha_enabled: true)
        allow_any_instance_of(SpamService).to receive(:check_for_spam?).and_return(true)
      end

      context 'when an issue is not identified as spam' do
        before do
          allow_any_instance_of(described_class).to receive(:verify_recaptcha).and_return(false)
          allow_any_instance_of(AkismetService).to receive(:is_spam?).and_return(false)
        end

        it 'does not create an issue' do
          expect { post_new_issue(title: '') }.not_to change(Issue, :count)
        end
      end

      context 'when an issue is identified as spam' do
        before { allow_any_instance_of(AkismetService).to receive(:is_spam?).and_return(true) }

        context 'when captcha is not verified' do
          def post_spam_issue
            post_new_issue(title: 'Spam Title', description: 'Spam lives here')
          end

          before { allow_any_instance_of(described_class).to receive(:verify_recaptcha).and_return(false) }

          it 'rejects an issue recognized as a spam' do
            expect { post_spam_issue }.not_to change(Issue, :count)
          end

          it 'creates a spam log' do
            post_spam_issue
            spam_logs = SpamLog.all

            expect(spam_logs.count).to eq(1)
            expect(spam_logs.first.title).to eq('Spam Title')
            expect(spam_logs.first.recaptcha_verified).to be_falsey
          end

          it 'does not create an issue when it is not valid' do
            expect { post_new_issue(title: '') }.not_to change(Issue, :count)
          end

          it 'does not create an issue when recaptcha is not enabled' do
            stub_application_setting(recaptcha_enabled: false)

            expect { post_spam_issue }.not_to change(Issue, :count)
          end
        end

        context 'when captcha is verified' do
          let!(:spam_logs) { create_list(:spam_log, 2, user: user, title: 'Title') }

          def post_verified_issue
            post_new_issue({}, { spam_log_id: spam_logs.last.id, recaptcha_verification: true } )
          end

          before do
            allow_any_instance_of(described_class).to receive(:verify_recaptcha).and_return(true)
          end

          it 'accepts an issue after recaptcha is verified' do
            expect { post_verified_issue }.to change(Issue, :count)
          end

          it 'marks spam log as recaptcha_verified' do
            expect { post_verified_issue }.to change { SpamLog.last.recaptcha_verified }.from(false).to(true)
          end

          it 'does not mark spam log as recaptcha_verified when it does not belong to current_user' do
            spam_log = create(:spam_log)

            expect { post_new_issue({}, { spam_log_id: spam_log.id, recaptcha_verification: true } ) }.
              not_to change { SpamLog.last.recaptcha_verified }
          end
        end
      end
    end

    context 'user agent details are saved' do
      before do
        request.env['action_dispatch.remote_ip'] = '127.0.0.1'
      end

      it 'creates a user agent detail' do
        expect { post_new_issue }.to change(UserAgentDetail, :count).by(1)
      end
    end

    context 'when description has slash commands' do
      before do
        sign_in(user)
      end

      it 'can add spent time' do
        issue = post_new_issue(description: '/spend 1h')

        expect(issue.total_time_spent).to eq(3600)
      end

      it 'can set the time estimate' do
        issue = post_new_issue(description: '/estimate 2h')

        expect(issue.time_estimate).to eq(7200)
      end
    end
  end

  describe 'POST #mark_as_spam' do
    context 'properly submits to Akismet' do
      before do
        allow_any_instance_of(AkismetService).to receive_messages(submit_spam: true)
        allow_any_instance_of(ApplicationSetting).to receive_messages(akismet_enabled: true)
      end

      def post_spam
        admin = create(:admin)
        create(:user_agent_detail, subject: issue)
        project.team << [admin, :master]
        sign_in(admin)
        post :mark_as_spam, {
          namespace_id: project.namespace,
          project_id: project,
          id: issue.iid
        }
      end

      it 'updates issue' do
        post_spam
        expect(issue.submittable_as_spam?).to be_falsey
      end
    end
  end

  describe "DELETE #destroy" do
    context "when the user is a developer" do
      before { sign_in(user) }
      it "rejects a developer to destroy an issue" do
        delete :destroy, namespace_id: project.namespace, project_id: project, id: issue.iid
        expect(response).to have_http_status(404)
      end
    end

    context "when the user is owner" do
      let(:owner)     { create(:user) }
      let(:namespace) { create(:namespace, owner: owner) }
      let(:project)   { create(:empty_project, namespace: namespace) }

      before { sign_in(owner) }

      it "deletes the issue" do
        delete :destroy, namespace_id: project.namespace, project_id: project, id: issue.iid

        expect(response).to have_http_status(302)
        expect(controller).to set_flash[:notice].to(/The issue was successfully deleted\./).now
      end

      it 'delegates the update of the todos count cache to TodoService' do
        expect_any_instance_of(TodoService).to receive(:destroy_issue).with(issue, owner).once

        delete :destroy, namespace_id: project.namespace, project_id: project, id: issue.iid
      end
    end
  end

  describe 'POST #toggle_award_emoji' do
    before do
      sign_in(user)
      project.team << [user, :developer]
    end

    it "toggles the award emoji" do
      expect do
        post(:toggle_award_emoji, namespace_id: project.namespace,
                                  project_id: project, id: issue.iid, name: "thumbsup")
      end.to change { issue.award_emoji.count }.by(1)

      expect(response).to have_http_status(200)
    end
  end
end
