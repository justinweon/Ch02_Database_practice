class UserService:
    def __init__(self, supabase):
        self.supabase = supabase

    def get_auth_user(self):
        response = self.supabase.auth.get_user()

        return response.user



    #프로필 생성 기능 추가 

    def create_profile(self, role, mobile, address):
        auth_user = self.get_auth_user()

        response = (self.supabase.table("user_details")
        .insert({
            "id":auth_user.id,
            "role" : role,
            "mobile" : mobile,
            "address" : address
        }).execute()
    )
        return response.data

    # 프로필 조회기능 추가
    def get_profile(self):
        auth_user = self.get_auth_user()

        response = (
             self.supabase.table("user_details")
             .select("*")
             .eq("id", auth_user.id)
             .maybe_single()
             .execute()
)
        return response.data    

    # 프로필 수정기능 추가
    def update_profile(self, mobile=None, address=None):
        auth_user = self.get_auth_user()

        update_data={}
        if mobile is not None:
            update_data["mobile"] = mobile
        if address is not None:
            update_data["address"]=address

        response = (
            self.supabase.table("user_details")
            .update(update_data)
            .eq("id", auth_user.id)
            .execute()
        )
        return response.data

    #프로필 지우기 기능 추가
    def delete_profile(self):
        auth_user = self.get_auth_user()

        response = (
            self.supabase.table("user_details")
            .delete()
            .eq("id",auth_user.id)
            .execute()
        )
        return response.data