CLASS zpm_order_mail DEFINITION
  PUBLIC FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_apj_rt_exec_object.
    INTERFACES if_apj_dt_exec_object.
ENDCLASS.



CLASS ZPM_ORDER_MAIL IMPLEMENTATION.


  METHOD if_apj_dt_exec_object~get_parameters.
    et_parameter_def = VALUE #( ( selname        = 'P_DATE'
                                  kind           = if_apj_dt_exec_object=>parameter
                                  datatype       = 'I'
*                                  length         = 10
                                  param_text     = 'Gün'
                                  changeable_ind = abap_true  ) ).
  ENDMETHOD.


  METHOD if_apj_rt_exec_object~execute.
    TRY.
        DATA(l_log) = cl_bali_log=>create_with_header( cl_bali_header_setter=>create( object    = 'ZPM_INSPECTION_LOG'
                                                                                      subobject = 'LOG' ) ).

        LOOP AT it_parameters INTO DATA(l_parameter).
          CASE l_parameter-selname.
            WHEN 'P_DATE'.
              DATA(days) = l_parameter-low.
          ENDCASE.
        ENDLOOP.

        TYPES: BEGIN OF ty_order,

                 equipment TYPE i_technicalobject-equipment,
                 order     TYPE aufnr,

               END OF ty_order.

        DATA lt_order TYPE TABLE OF ty_order.

        DATA(current_date) = cl_abap_context_info=>get_system_date( ).
        current_date += days.

        IF days IS NOT INITIAL.

          SELECT FROM i_technicalobject
            FIELDS Equipment,
                   TechnicalObjectDescription,
                   TechnicalObjectType,
                   YY1_Region_IEQ
*      WHERE TechnicalObjectType   = 'DORSE'
            WHERE YY1_InspectionEnd_IEQ = @current_date
            INTO TABLE @DATA(equipment).
        ELSEIF days = 0.

          SELECT FROM i_technicalobject
            FIELDS Equipment,
                   TechnicalObjectDescription,
                   TechnicalObjectType,
                   YY1_Region_IEQ
*      WHERE TechnicalObjectType   = 'DORSE'
            WHERE YY1_InspectionEnd_IEQ <= @current_date
            INTO TABLE @DATA(equipment_expire).

        ENDIF.

        IF days = 30.
          LOOP AT equipment INTO DATA(ls_equipment) WHERE TechnicalObjectType = 'DORSE'.

            MODIFY ENTITIES OF I_MaintenanceOrderTP
                   ENTITY MaintenanceOrder
                   CREATE
                   FIELDS ( MaintenanceOrderType
                            MaintenanceOrderDesc
                            MainWorkCenter
                            MaintenancePlanningPlant
                            MaintenancePlant
                            Equipment )
                   WITH VALUE #( ( %cid  = 'ORDER'
                                   %data = VALUE #( MaintenanceOrderType     = 'YA05'
                                                    MaintenanceOrderDesc     = ls_equipment-TechnicalObjectDescription
                                                    MainWorkCenter           = 'HMLGNL'
                                                    MaintenancePlanningPlant = '1000'
                                                    MaintenancePlant         = '1000'
                                                    Equipment                = ls_equipment-Equipment ) ) )
                   MAPPED   DATA(mapped_create_orders)
                   FAILED   DATA(reported_create_orders)
                   " TODO: variable is assigned but never used (ABAP cleaner)
                   REPORTED DATA(ls_reported_modify).

            IF reported_create_orders IS NOT INITIAL.
              DATA(item) = cl_bali_message_setter=>create_from_bapiret2(
                               message_data = VALUE #( id         = 'ZPM_INSPECTION_MAIL'
                                                       type       = 'E'
                                                       number     = 001
                                                       message_v1 = ls_equipment-TechnicalObjectDescription ) ).
              l_log->add_item( item = item ).
            ENDIF.

            COMMIT ENTITIES BEGIN
                   RESPONSE OF I_MaintenanceOrderTP
                   " TODO: variable is assigned but never used (ABAP cleaner)
                   FAILED   DATA(failed_early_commit)
                   " TODO: variable is assigned but never used (ABAP cleaner)
                   REPORTED DATA(reported_early_commit).

            LOOP AT mapped_create_orders-maintenanceorder ASSIGNING FIELD-SYMBOL(<mapped_early_order>).
              CONVERT KEY OF I_MaintenanceOrderTP FROM <mapped_early_order>-%key TO DATA(lv_order_key).
              <mapped_early_order>-%key = lv_order_key.
              APPEND VALUE #( equipment = ls_equipment-Equipment
                              order     = lv_order_key-MaintenanceOrder ) TO lt_order.
            ENDLOOP.

            COMMIT ENTITIES END.

          ENDLOOP.
        ENDIF.

        SELECT SINGLE FROM ZI_PmMailMaintenance WITH
          PRIVILEGED ACCESS
          FIELDS Sender,
                 Recipient
          WHERE MailType = '01'
          INTO @DATA(mail_partners).
        IF sy-subrc = 0 AND mail_partners-Sender IS NOT INITIAL AND mail_partners-Recipient IS NOT INITIAL.

          DATA(lo_mail) = cl_bcs_mail_message=>create_instance( ).
*        lo_mail->set_sender( 'do.not.reply@my418838.mail.s4hana.ondemand.com' ). """"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
*        lo_mail->add_recipient( 'berk.tahtaci@nagarro.com' ).
          lo_mail->set_sender( CONV #( mail_partners-Sender ) ).
          lo_mail->add_recipient( CONV #( mail_partners-Recipient ) ).
          lo_mail->set_subject( |TUV Muayenesi Yaklaşan Dorseler hk. | ).

          DATA(body_html) = |<p>Sayın ilgililer,</p>| &&
                      |<p>TUV muayenesine { days } gün kalan araçlar aşağıdakiler gibidir:</p>| &&
                      |<table border="1">| &&
                      |  <thead>| &&
                                |    <tr>| &&
                      |      <th>Plaka</th>| &&
                      |      <th>Bölge</th>| &&
                      |      <th>Sipariş</th>| &&
                      |    </tr>| &&
                      |  </thead>| &&
                      |  <tbody>|.

          LOOP AT equipment INTO ls_equipment WHERE TechnicalObjectType = 'DORSE'.
            body_html = |{ body_html }| &&
                      |    <tr>| &&
                      |      <td>{ ls_equipment-TechnicalObjectDescription }</td>| &&
                      |      <td>{ ls_equipment-YY1_Region_IEQ }</td>|.
            TRY.
                DATA(lv_url) = |https://| & |{ cl_abap_context_info=>get_system_url( ) }|
                 & |#MaintenanceOrder-displayFactSheet&/C_ObjPgMaintOrder|
                & |('{ lt_order[ equipment = ls_equipment-Equipment ]-order }')|. "('4000001')
                body_html = |{ body_html }<td><a href="{ lv_url }">{ lt_order[
                                                                         equipment = ls_equipment-Equipment ]-order ALPHA = OUT }</a></td>|.
              CATCH cx_abap_context_info_error ##NO_HANDLER.
              CATCH cx_sy_itab_line_not_found ##NO_HANDLER.
                body_html = |{ body_html }<td></td>|.
            ENDTRY.

            body_html = |{ body_html }    </tr>|.
          ENDLOOP.
          IF sy-subrc = 0.
            body_html = |{ body_html }| &&
                              |  </tbody>| &&
                             |</table>|.
            lo_mail->set_main( cl_bcs_mail_textpart=>create_text_html( body_html ) ).
            lo_mail->send( ).
            COMMIT WORK AND WAIT.
          ENDIF.

          FREE lo_mail.
          Lo_mail = cl_bcs_mail_message=>create_instance( ).
          lo_mail->set_sender( 'do.not.reply@my418838.mail.s4hana.ondemand.com' ). """"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
          lo_mail->add_recipient( 'berk.tahtaci@nagarro.com' ).
          lo_mail->set_subject( |TUV Muayenesi Yaklaşan Araçlar hk. | ).

          body_html = |<p>Sayın ilgililer,</p>| &&
                      |<p>TUV muayenesine { days } gün kalan araçlar aşağıdakiler gibidir:</p>| &&
                      |<table border="1">| &&
                      |  <thead>| &&
                                |    <tr>| &&
                      |      <th>Plaka</th>| &&
                      |      <th>Bölge</th>| &&
*                |      <th>Sipariş</th>| &&
                      |    </tr>| &&
                      |  </thead>| &&
                      |  <tbody>|.

          LOOP AT equipment INTO ls_equipment WHERE TechnicalObjectType <> 'DORSE'.
            body_html = |{ body_html }| &&
                      |    <tr>| &&
                      |      <td>{ ls_equipment-TechnicalObjectDescription }</td>| &&
                      |      <td>{ ls_equipment-YY1_Region_IEQ }</td>| &&
                      |    </tr>|.

          ENDLOOP.
          IF sy-subrc = 0.
            body_html = |{ body_html }| &&
                              |  </tbody>| &&
                             |</table>|.
            lo_mail->set_main( cl_bcs_mail_textpart=>create_text_html( body_html ) ).
            lo_mail->send( ).
            COMMIT WORK AND WAIT.
          ENDIF.

          FREE lo_mail.
          Lo_mail = cl_bcs_mail_message=>create_instance( ).
*          lo_mail->set_sender( 'do.not.reply@my418838.mail.s4hana.ondemand.com' ). """"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
*          lo_mail->add_recipient( 'berk.tahtaci@nagarro.com' ).
          lo_mail->set_sender( CONV #( mail_partners-Sender ) ).
          lo_mail->add_recipient( CONV #( mail_partners-Recipient ) ).
          lo_mail->set_subject( |TUV Muayenesi Geçmiş Araçlar hk. | ).

          body_html = |<p>Sayın ilgililer,</p>| &&
                      |<p>TUV muayenesi geçmiş araçlar aşağıdakiler gibidir:</p>| &&
                      |<table border="1">| &&
                      |  <thead>| &&
                                |    <tr>| &&
                      |      <th>Plaka</th>| &&
                      |      <th>Bölge</th>| &&
                      |    </tr>| &&
                      |  </thead>| &&
                      |  <tbody>|.

          " TODO: variable is assigned but never used (ABAP cleaner)
          LOOP AT equipment_expire INTO DATA(ls_equipment_expire).
            body_html = |{ body_html }| &&
                      |    <tr>| &&
                      |      <td>{ ls_equipment-TechnicalObjectDescription }</td>| &&
                      |      <td>{ ls_equipment-YY1_Region_IEQ }</td>| &&
                      |    </tr>|.

          ENDLOOP.
          IF sy-subrc = 0.
            body_html = |{ body_html }| &&
                              |  </tbody>| &&
                             |</table>|.
            lo_mail->set_main( cl_bcs_mail_textpart=>create_text_html( body_html ) ).
            lo_mail->send( ).
            COMMIT WORK AND WAIT.
          ENDIF.

        ELSE.
          item = cl_bali_message_setter=>create_from_bapiret2( message_data = VALUE #( id         = 'ZPM_MAIL_GENERAL'
                                                                                       type       = 'E'
                                                                                       number     = 001
                                                                                       message_v1 = '01' ) ).
          l_log->add_item( item = item ).
        ENDIF.

        IF l_log->get_all_items( ) IS NOT INITIAL.
          cl_bali_log_db=>get_instance( )->save_log( log                        = l_log
                                                     assign_to_current_appl_job = abap_true ).
          COMMIT WORK.
        ENDIF.
      CATCH cx_bali_runtime INTO DATA(l_runtime_exception) ##NO_HANDLER. " TODO: variable is assigned but never used (ABAP cleaner)

    ENDTRY.
  ENDMETHOD.
ENDCLASS.
