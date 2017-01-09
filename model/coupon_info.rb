# -*- coding: utf-8 -*-

require 'httpclient'
require 'uri'
require 'webrick'
require 'json'

require_relative 'coupon'
require_relative 'hdo_info'

module Plugin::IIJ_COUPON_CHECKER
  class CouponInfo < Retriever::Model

    attr_reader :hddServiceCode, :hdo_info, :coupon, :plan

    @coupon_url = 'https://api.iijmio.jp/mobile/d/v1/coupon/'

    # モデル
    field.string :hddServiceCode
    field.has :hdoInfo, Plugin::IIJ_COUPON_CHECKER::HDOInfo
    field.has :coupon, [Plugin::IIJ_COUPON_CHECKER::Coupon]
    field.string :plan


    class << self

      # 認証
      # @return [Delayer::Deferred::Deferredable] 認証結果を引数にcallbackするDeferred
      def auth
        Thread.new {
          Delayer::Deferred.fail('Developer ID not defined') unless UserConfig['iij_developer_id']
          query = {:response_type => 'token',
                   :client_id => UserConfig['iij_developer_id'],
                   :state => 'mikutter_iij_coupon_checker',
                   :redirect_uri => 'http://localhost:8080/'
          }.to_hash
          # リクエスト
          Plugin.call(:open, "https://api.iijmio.jp/mobile/d/v1/authorization/?#{query.map { |k, v| "#{k}=#{v}" }.join('&')}")
          Thread.new {
            document_root = File.join(__dir__, '../www/')
            # OAuth認証用サーバの設定
            config = {
                :BindAddress => 'localhost',
                :Port => 8080,
                :DocumentRoot => document_root
            }

            @server = WEBrick::HTTPServer.new(config)
            @server.mount_proc('/') do |req, res|
              res.body = File.open(File.expand_path('index.html', document_root))
              res.content_type = 'text/html'
              res.chunked = true
              res.status == 451 if req.path.to_s.include?('favicon.ico')

              if req.query&.empty?
                access_token = req.query['access_token']
                UserConfig['iij_access_token'] = access_token unless access_token.empty?
              end
            end
            trap('INT') { @server.shutdown }
            @server.start
            @server
          }
        }
      end


      # クーポン情報の取得
      # @return [Delayer::Deferred::Deferredable] クーポンのモデルを引数にcallbackするDeferred
      # ステータスコードについてはAPIレファレンスを参照すること {@see https://www.iijmio.jp/hdd/coupon/mioponapi.jsp}
      def get_info
        Delayer::Deferred.fail("デベロッパーIDが存在しません\nIDを設定してください\n") unless UserConfig['iij_developer_id']
        Thread.new {
          client = HTTPClient.new
          client.default_header = {
              :'Content-Type' => 'application/json',
              :'X-IIJmio-Developer' => UserConfig['iij_developer_id'],
              :'X-IIJmio-Authorization' => UserConfig['iij_access_token']
          }.to_hash
          client.get(@coupon_url)
        }.next { |response|
          Plugin::IIJ_COUPON_CHECKER::CouponInfo.auth if (response&.status_code == 403)
          Delayer::Deferred.fail(response) unless (response&.status_code == 200)

          info = []
          JSON.parse(response.content)['couponInfo'].each { |data|
            # SIM内クーポン
            sim_coupon = Plugin::IIJ_COUPON_CHECKER::Coupon.new(volume: data.dig('hdoInfo', 0, 'coupon', 0, 'volume'),
                                                                expire: data.dig('hdoInfo', 0, 'coupon', 0, 'expire'),
                                                                type: data.dig('hdoInfo', 0, 'coupon', 0, 'type'))
            @hdo_info = Plugin::IIJ_COUPON_CHECKER::HDOInfo.new(regulation: data.dig('hdoInfo', 0, 'regulation'),
                                                                couponUse: data.dig('hdoInfo', 0, 'couponUse'),
                                                                iccid: data.dig('hdoInfo', 0, 'iccid'),
                                                                coupon: sim_coupon,
                                                                hdoServiceCode: data.dig('hdoInfo', 0, 'hdoServiceCode'),
                                                                voice: data.dig('hdoInfo', 0, 'voice'),
                                                                sms: data.dig('hdoInfo', 0, 'sms'),
                                                                number: data.dig('hdoInfo', 0, 'number'))

            coupons = []
            data.dig('coupon').each { |c|
              coupons << Plugin::IIJ_COUPON_CHECKER::Coupon.new(volume: c.dig('volume'),
                                                                expire: c.dig('expire'),
                                                                type: c.dig('typo'))
            }
            # バンドルクーポンや課金クーポン
            info << Plugin::IIJ_COUPON_CHECKER::CouponInfo.new(hddServiceCode: data.dig('hddServiceCode'),
                                                               hdo_info: @hdo_info,
                                                               coupon: coupons,
                                                               plan: data.dig('plan'))
          }
          info
        }
      end


      # クーポンの利用状態の切り替え（On/Off）
      # @param [String] hdo hdoServiceCode
      # @param [Bool] is_valid クーポンのオン・オフのフラグ
      def switch(hdo, is_valid)
        Thread.new {
          Delayer::Deferred.fail("デベロッパーIDが存在しません\nIDを設定してください\n") unless UserConfig['iij_developer_id']
          client = HTTPClient.new
          data = {:couponInfo => [{:hdoInfo => [{:hdoServiceCode => hdo, :couponUse => is_valid}]}]}.to_hash
          client.default_header = {
              :'Content-Type' => 'application/json',
              :'X-IIJmio-Developer' => UserConfig['iij_developer_id'],
              :'X-IIJmio-Authorization' => UserConfig['iij_access_token']
          }.to_hash
          client.put(@coupon_url, JSON.generate(data))
        }.next { |response|
          auth if (response&.status_code == 403) # TODO: returnCodeでマッチングする
          Delayer::Deferred.fail(response) unless (response&.status_code == 200)
          response
        }
      end

    end

  end
end